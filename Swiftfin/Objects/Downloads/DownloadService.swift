//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import Combine
import Defaults
import FactoryKit
import Foundation
import Get
import JellyfinAPI
import Logging
import PlayerCore

extension Container {

    var downloadService: Factory<DownloadService> {
        self { @MainActor in DownloadService() }
            .singleton
    }
}

/// Personal fork: downloads episodes and movies as offline HLS with Apple's background downloader, one at a time.
///
/// The server makes the stream (copying small sources, shrinking big ones, see `downloadStreamRequest`), so every
/// download plays in the Apple player. Records live in `DownloadStore`.
@MainActor
final class DownloadService: NSObject, ObservableObject {

    /// Set by the app delegate when iOS wakes the app for finished background downloads.
    static var backgroundCompletionHandler: (() -> Void)?

    private let logger = Logger.swiftfin()

    @Injected(\.downloadStore)
    private var store: DownloadStore

    private var session: AVAssetDownloadURLSession!
    private var tasks: [String: AVAggregateAssetDownloadTask] = [:]
    /// Per item, the progress of each media selection being downloaded.
    private var selectionProgress: [String: [AVMediaSelection: Double]] = [:]
    private var playSessionIDs: [String: String] = [:]
    /// Downloads between leaving the queue and having a task, counted towards the limits.
    private var startingIDs: Set<String> = []

    /// How long to wait before asking a busy server again.
    private let serverBusyRetryDelay: Duration = .seconds(30)
    /// Downloads the user cancelled; other cancellations (force quit) get Retry.
    private var cancelRequestedIDs: Set<String> = []
    /// Keeps the server's conversion alive. The downloader never pauses between segments, and the server ends a
    /// conversion that hasn't been pinged for 60 seconds.
    private var keepAliveTasks: [String: Task<Void, Never>] = [:]
    private var sessionCancellable: AnyCancellable?

    override init() {
        super.init()

        let identifier = "\(Bundle.main.bundleIdentifier ?? "swiftfin").downloads"
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        session = AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: self,
            delegateQueue: .main
        )

        sessionCancellable = Container.shared.userSessionManager().$currentSession
            .compactMap(\.self)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task {
                    await self?.reattach()
                }
            }
    }

    // MARK: Actions

    /// Queues `item` for download. Returns once it's queued.
    func download(_ item: BaseItemDto) async throws {
        guard let userSession = Container.shared.currentUserSession(), let itemID = item.id,
              store.record(for: itemID) == nil else { return }

        let fullItem = try await item.getFullItem(userSession: userSession)
        let mediaSource = try await playbackMediaSource(for: fullItem, userSession: userSession)

        var segments: [MediaSegmentDto] = []
        if let result = try? await userSession.client.send(Paths.getItemSegments(itemID: itemID)).value {
            segments = result.items ?? []
        }

        let request = streamRequest(for: mediaSource)
        let runtime = Double(mediaSource.runTimeTicks ?? fullItem.runTimeTicks ?? 0) / 10_000_000

        let record = DownloadRecord(
            id: itemID,
            serverID: userSession.server.id,
            userID: userSession.user.id,
            item: fullItem,
            mediaSource: mediaSource,
            segments: segments,
            assetRelativePath: nil,
            state: .queued,
            estimatedBytes: estimatedDownloadBytes(request, sourceBitrate: mediaSource.bitrate, runtimeSeconds: runtime),
            downloadedAt: .now
        )
        store.upsert(record)

        await saveImages(for: record)
        startNextIfIdle()
    }

    /// Cancels a download in progress, or deletes a finished one.
    func cancelOrDelete(itemID: String) {
        if let task = tasks.removeValue(forKey: itemID) {
            cancelRequestedIDs.insert(itemID)
            task.cancel()
            stopEncoding(itemID: itemID)
        }
        store.delete(itemID: itemID)
        startNextIfIdle()
    }

    func retry(itemID: String) {
        guard var record = store.record(for: itemID) else { return }
        removeAsset(of: record)
        record.assetRelativePath = nil
        record.state = .queued
        store.upsert(record)
        startNextIfIdle()
    }

    // MARK: Queue

    /// Starts the queued downloads the limits allow (`downloadsToStart`): one the server shrinks at a time, copies
    /// alongside, three at most.
    private func startNextIfIdle() {
        let queued = store.records
            .filter { $0.state == .queued }
            .map { QueuedDownload(id: $0.id, copiesVideo: copiesVideo($0)) }
        let running = Set(tasks.keys).union(startingIDs).map { id in
            RunningDownload(id: id, copiesVideo: store.record(for: id).map(copiesVideo) ?? true)
        }

        for nextID in downloadsToStart(queued: queued, running: running) {
            guard let next = store.record(for: nextID) else { continue }
            startingIDs.insert(nextID)

            Task {
                do {
                    try await start(next)
                    startingIDs.remove(nextID)
                } catch {
                    startingIDs.remove(nextID)
                    logger.error("Unable to start download: \(error.localizedDescription)")
                    fail(itemID: nextID, message: error.localizedDescription)
                    startNextIfIdle()
                }
            }
        }
    }

    private func copiesVideo(_ record: DownloadRecord) -> Bool {
        streamRequest(for: record.mediaSource).copiesVideo
    }

    /// The server is converting as many downloads as it allows: wait, then queue it again.
    private func waitForServer(itemID: String) {
        store.updateAnyUser(itemID: itemID) { $0.state = .waiting }

        Task {
            try? await Task.sleep(for: serverBusyRetryDelay)
            guard store.record(for: itemID)?.state == .waiting else { return }
            store.updateAnyUser(itemID: itemID) { $0.state = .queued }
            startNextIfIdle()
        }
    }

    private func start(_ record: DownloadRecord) async throws {
        guard let userSession = Container.shared.currentUserSession(),
              let accessToken = userSession.client.accessToken
        else { return }

        // The prefix tells the server this is a download, for its limit across devices.
        let playSessionID = "download-\(UUID().uuidString)"
        let url = try masterURL(
            for: record,
            serverURL: userSession.client.configuration.url,
            deviceID: userSession.client.configuration.deviceID,
            accessToken: accessToken,
            playSessionID: playSessionID
        )

        // Ask first: a busy server answers 503 before anything is downloaded.
        var preflight = URLRequest(url: url)
        preflight.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: preflight)
        if (response as? HTTPURLResponse)?.statusCode == 503 {
            waitForServer(itemID: record.id)
            return
        }

        let asset = AVURLAsset(url: url)
        let preferred = try await asset.load(.preferredMediaSelection)
        var selections = [preferred]

        if let legible = try await asset.loadMediaSelectionGroup(for: .legible) {
            for option in legible.options {
                guard let selection = preferred.mutableCopy() as? AVMutableMediaSelection else { continue }
                selection.select(option, in: legible)
                selections.append(selection)
            }
        }

        guard let task = session.aggregateAssetDownloadTask(
            with: asset,
            mediaSelections: selections,
            assetTitle: record.item.displayTitle,
            assetArtworkData: nil,
            options: nil
        ) else {
            throw ErrorMessage(L10n.downloadIncomplete)
        }

        // Cancelled while starting.
        guard var updated = store.record(for: record.id) else {
            playSessionIDs[record.id] = playSessionID
            stopEncoding(itemID: record.id)
            return
        }

        task.taskDescription = record.id
        tasks[record.id] = task
        keepAlive(itemID: record.id, playSessionID: playSessionID, client: userSession.client)
        selectionProgress[record.id] = [:]
        playSessionIDs[record.id] = playSessionID

        updated.state = .downloading(progress: 0)
        updated.playSessionID = playSessionID
        store.upsert(updated)

        task.resume()
    }

    /// Re-attaches background downloads after a relaunch, and marks downloads that lost their task as failed.
    private func reattach() async {
        let running = await session.allTasks.compactMap { $0 as? AVAggregateAssetDownloadTask }

        for task in running {
            guard let itemID = task.taskDescription else { continue }

            // Another user's downloads keep going; only downloads nobody has any more are cancelled.
            guard store.hasRecordForAnyUser(itemID: itemID) else {
                task.cancel()
                continue
            }

            tasks[itemID] = task
            if let record = store.record(for: itemID), let playSessionID = record.playSessionID,
               let client = Container.shared.currentUserSession()?.client
            {
                playSessionIDs[itemID] = playSessionID
                keepAlive(itemID: itemID, playSessionID: playSessionID, client: client)
            }
        }

        for var record in store.records where tasks[record.id] == nil {
            switch record.state {
            case .downloading:
                // It may have finished while the app was closed.
                if isPlayableOffline(record) {
                    record.state = .complete
                    store.upsert(record)
                    protectFromPurging(record)
                } else {
                    fail(itemID: record.id, message: L10n.downloadInterrupted)
                }
            case .complete:
                // iOS may have removed it to free up space.
                if !isPlayableOffline(record) {
                    fail(itemID: record.id, message: L10n.downloadRemoved)
                }
            default: ()
            }
        }

        startNextIfIdle()
    }

    private func fail(itemID: String, message: String) {
        tasks[itemID] = nil
        store.updateAnyUser(itemID: itemID) { record in
            removeAsset(of: record)
            record.assetRelativePath = nil
            record.state = .failed(message: message)
        }
    }

    private func finish(itemID: String, error: Error?) {
        tasks[itemID] = nil
        selectionProgress[itemID] = nil
        stopEncoding(itemID: itemID)
        let cancelRequested = cancelRequestedIDs.remove(itemID) != nil

        defer { startNextIfIdle() }

        var playable = false
        store.updateAnyUser(itemID: itemID) { record in
            playable = isPlayableOffline(record)
        }

        let outcome = downloadFinishOutcome(
            failed: error != nil,
            cancelled: (error as? NSError)?.code == NSURLErrorCancelled,
            cancelRequested: cancelRequested,
            playableOffline: playable
        )

        switch outcome {
        case .ignore:
            return
        case .failed:
            let message = if let error, (error as NSError).code != NSURLErrorCancelled {
                error.localizedDescription
            } else if error != nil {
                L10n.downloadInterrupted
            } else {
                L10n.downloadIncomplete
            }
            if let error {
                logger.error("Download failed: \(error.localizedDescription)")
            }
            fail(itemID: itemID, message: message)
        case .complete:
            store.updateAnyUser(itemID: itemID) { record in
                record.state = .complete
                protectFromPurging(record)
            }
        }
    }

    private func isPlayableOffline(_ record: DownloadRecord) -> Bool {
        guard let url = store.assetURL(for: record) else { return false }
        return AVURLAsset(url: url).assetCache?.isPlayableOffline == true
    }

    /// Asks iOS not to remove the download to free up space.
    private func protectFromPurging(_ record: DownloadRecord) {
        guard let url = store.assetURL(for: record) else { return }
        let policy = AVMutableAssetDownloadStorageManagementPolicy()
        policy.priority = .important
        AVAssetDownloadStorageManager.shared().setStorageManagementPolicy(policy, for: url)
    }

    // MARK: Server

    /// The media source with the user's audio preference applied, as the server reports it for playback.
    private func playbackMediaSource(for item: BaseItemDto, userSession: UserSession) async throws -> MediaSourceInfo {
        guard let itemID = item.id, let initial = item.mediaSources?.first else {
            throw ErrorMessage(L10n.unknownError)
        }

        var info = PlaybackInfoDto()
        info.deviceProfile = DeviceProfile.build(for: .native, compatibilityMode: .auto, maxBitrate: copyBitrateCeiling)
        info.maxStreamingBitrate = copyBitrateCeiling
        info.mediaSourceID = initial.id
        info.userID = userSession.user.id

        let response = try await userSession.client.send(Paths.getPostedPlaybackInfo(itemID: itemID, info))
        let sources = response.value.mediaSources ?? []
        return sources.first { $0.id == initial.id } ?? sources.first ?? initial
    }

    private let copyBitrateCeiling = 120_000_000

    private func streamRequest(for mediaSource: MediaSourceInfo) -> DownloadStreamRequest {
        let streams = mediaSource.mediaStreams ?? []
        let video = streams.first { $0.type == .video }
        let firstTextSubtitle = streams.first { $0.type == .subtitle && $0.isTextSubtitleStream == true }

        return downloadStreamRequest(
            sourceVideoCodec: video?.codec,
            sourceVideoBitrate: video?.bitRate ?? mediaSource.bitrate,
            firstTextSubtitleIndex: firstTextSubtitle?.index,
            quality: Defaults[.downloadQuality]
        )
    }

    private func masterURL(
        for record: DownloadRecord,
        serverURL: URL,
        deviceID: String,
        accessToken: String,
        playSessionID: String
    ) throws -> URL {
        let request = streamRequest(for: record.mediaSource)
        let streams = record.mediaSource.mediaStreams ?? []
        let audioIndex = record.mediaSource.defaultAudioStreamIndex ?? streams.first { $0.type == .audio }?.index

        var components = URLComponents(
            url: serverURL.appendingPathComponent("Videos/\(record.id)/master.m3u8"),
            resolvingAgainstBaseURL: false
        )
        var query: [URLQueryItem] = [
            .init(name: "MediaSourceId", value: record.mediaSource.id ?? record.id),
            .init(name: "DeviceId", value: deviceID),
            .init(name: "PlaySessionId", value: playSessionID),
            .init(name: "VideoCodec", value: request.videoCodecs),
            .init(name: "AudioCodec", value: "aac"),
            .init(name: "VideoBitrate", value: String(request.videoBitrate)),
            .init(name: "AudioBitrate", value: String(request.audioBitrate)),
            .init(name: "TranscodingMaxAudioChannels", value: "2"),
            .init(name: "SegmentContainer", value: "mp4"),
            .init(name: "AllowVideoStreamCopy", value: "true"),
            .init(name: "ApiKey", value: accessToken),
        ]
        if let audioIndex {
            query.append(.init(name: "AudioStreamIndex", value: String(audioIndex)))
        }
        if let subtitleIndex = request.subtitleStreamIndex {
            query.append(.init(name: "SubtitleMethod", value: "Hls"))
            query.append(.init(name: "SubtitleStreamIndex", value: String(subtitleIndex)))
        }
        components?.queryItems = query

        guard let url = components?.url else { throw ErrorMessage(L10n.unknownError) }
        return url
    }

    private func keepAlive(itemID: String, playSessionID: String, client: JellyfinClient) {
        keepAliveTasks[itemID]?.cancel()
        keepAliveTasks[itemID] = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                _ = try? await client.send(Paths.pingPlaybackSession(playSessionID: playSessionID))
            }
        }
    }

    /// Ends the server's conversion for a finished or cancelled download.
    private func stopEncoding(itemID: String) {
        keepAliveTasks.removeValue(forKey: itemID)?.cancel()
        if playSessionIDs[itemID] == nil, let saved = store.record(for: itemID)?.playSessionID {
            playSessionIDs[itemID] = saved
        }
        guard let playSessionID = playSessionIDs.removeValue(forKey: itemID),
              let userSession = Container.shared.currentUserSession()
        else { return }

        let request = Request<Void>(
            path: "/Videos/ActiveEncodings",
            method: "DELETE",
            query: [
                ("deviceId", userSession.client.configuration.deviceID),
                ("playSessionId", playSessionID),
            ]
        )
        Task {
            _ = try? await userSession.client.send(request)
        }
    }

    // MARK: Files

    private func saveImages(for record: DownloadRecord) async {
        let item = record.item
        let options = ImageSourceOptions(maxWidth: 600)
        var images: [(DownloadStore.Image, URL?)] = []

        if item.type == .episode {
            images.append((.thumb, item.imageSource(.primary, environment: options).url))
            images.append((
                .series,
                item.imageSource(itemID: item.seriesID, .primary, tag: item.seriesPrimaryImageTag, environment: options).url
            ))
        } else {
            images.append((.thumb, item.imageSource(.backdrop, environment: options).url))
            images.append((.primary, item.imageSource(.primary, environment: options).url))
        }

        for (image, url) in images {
            guard let url, let (data, _) = try? await URLSession.shared.data(from: url) else { continue }
            try? data.write(to: store.imageURL(for: record, image: image), options: .atomic)
        }
    }

    private func removeAsset(of record: DownloadRecord) {
        guard let url = store.assetURL(for: record) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func updateProgress(itemID: String, selection: AVMediaSelection, progress: Double) {
        guard var record = store.record(for: itemID) else { return }

        selectionProgress[itemID, default: [:]][selection] = progress
        // The video comes with the first selection; the subtitle-only selections hardly report progress.
        let total = (selectionProgress[itemID] ?? [:]).values.max() ?? 0

        if case let .downloading(current) = record.state, total - current < 0.01, total < 1 {
            return
        }
        record.state = .downloading(progress: min(total, 1))
        store.updateInMemory(record)
    }
}

// MARK: AVAssetDownloadDelegate

extension DownloadService: AVAssetDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        let itemID = aggregateAssetDownloadTask.taskDescription
        MainActor.assumeIsolated {
            guard let itemID else { return }
            store.updateAnyUser(itemID: itemID) { record in
                record.assetRelativePath = downloadAssetRelativePath(location.path(percentEncoded: false))
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange,
        for mediaSelection: AVMediaSelection
    ) {
        let itemID = aggregateAssetDownloadTask.taskDescription
        let loaded = loadedTimeRanges.map(\.timeRangeValue.duration.seconds).reduce(0, +)
        let expected = timeRangeExpectedToLoad.duration.seconds
        let progress = expected > 0 ? loaded / expected : 0

        MainActor.assumeIsolated {
            guard let itemID else { return }
            updateProgress(itemID: itemID, selection: mediaSelection, progress: progress)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let itemID = task.taskDescription
        MainActor.assumeIsolated {
            guard let itemID else { return }
            finish(itemID: itemID, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            Self.backgroundCompletionHandler?()
            Self.backgroundCompletionHandler = nil
        }
    }
}
