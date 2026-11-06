//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import FactoryKit
import Foundation
import JellyfinAPI

#if os(iOS)
import PlayerCore
#endif

// TODO: respond properly to end of playback
//       - when item changes
// TODO: only send stop on manager stop, not per-item

class MediaProgressObserver: ViewModel, MediaPlayerObserver {

    weak var manager: MediaPlayerManager? {
        didSet {
            if let manager {
                setup(with: manager)
            }
        }
    }

    private let timer = PokeIntervalTimer()
    private var hasSentStart = false
    private var item: MediaPlayerItem?
    private var lastPlaybackRequestStatus: MediaPlayerManager.PlaybackRequestStatus = .playing

    init(item: MediaPlayerItem) {
        self.item = item
        super.init()
        startTracking(item)
    }

    // Personal fork: a brief play that never reached the saved spot keeps the saved spot (`reportedPosition`), so
    // opening something by mistake, or before the resume seek lands, can't wipe where you were.
    private var savedSeconds: Double?
    private var furthestSeconds: Double = 0
    private var itemStartedAt = Date.now

    private func startTracking(_ item: MediaPlayerItem?) {
        savedSeconds = item?.baseItem.startSeconds?.seconds
        furthestSeconds = 0
        itemStartedAt = .now
    }

    /// The position to report for the current item.
    private var reportSeconds: Duration? {
        guard let seconds = manager?.seconds else { return nil }
        #if os(iOS)
        // The first moments still show the saved spot, before playback has really moved.
        if Date.now.timeIntervalSince(itemStartedAt) > 2 {
            furthestSeconds = max(furthestSeconds, seconds.seconds)
        }
        let position = reportedPosition(
            current: seconds.seconds,
            saved: savedSeconds,
            furthestReached: furthestSeconds,
            secondsPlayed: Date.now.timeIntervalSince(itemStartedAt)
        )
        return .seconds(position)
        #else
        return seconds
        #endif
    }

    private func sendReport() {
        guard let item else { return }
        recordDownloadProgress(for: item)

        switch lastPlaybackRequestStatus {
        case .playing:
            if hasSentStart {
                sendProgressReport(for: item, seconds: reportSeconds)
            } else {
                sendStartReport(for: item, seconds: reportSeconds)
            }
        case .paused:
            sendProgressReport(for: item, seconds: reportSeconds, isPaused: true)
        }
    }

    private func setup(with manager: MediaPlayerManager) {
        cancellables = []

        timer.sink { [weak self] in
            self?.sendReport()
            self?.timer.poke()
        }
        .store(in: &cancellables)

        manager.actions
            .sink { [weak self] in self?.didReceive(action: $0) }
            .store(in: &cancellables)

        manager.$playbackItem
            .sink { [weak self] in self?.playbackItemDidChange($0) }
            .store(in: &cancellables)

        manager.$playbackRequestStatus
            .sink { [weak self] in self?.playbackRequestStatusDidChange($0) }
            .store(in: &cancellables)

        Notifications[.applicationWillTerminate]
            .publisher
            .sink { [weak self] _ in self?.endPlaybackSession() }
            .store(in: &cancellables)
    }

    private func endPlaybackSession() {
        guard let item else { return }
        recordDownloadProgress(for: item)
        sendStopReport(for: item, seconds: reportSeconds)
    }

    /// Personal fork: a download also saves its position locally, as the server may be out of reach.
    private func recordDownloadProgress(for item: MediaPlayerItem) {
        #if os(iOS)
        guard item.isDownloaded else { return }
        Container.shared.downloadProgressSync().record(
            itemID: item.baseItem.id,
            positionTicks: reportSeconds?.ticks,
            runtimeTicks: item.baseItem.runTimeTicks
        )
        #endif
    }

    private func playbackItemDidChange(_ newItem: MediaPlayerItem?) {
        timer.poke()

        if let item, newItem !== item {
            endPlaybackSession()
            self.item = newItem
            startTracking(newItem)
            self.hasSentStart = false
            sendReport()
        }
    }

    private func playbackRequestStatusDidChange(_ newStatus: MediaPlayerManager.PlaybackRequestStatus) {
        timer.poke()
        lastPlaybackRequestStatus = newStatus
    }

    // TODO: respond to error
    // TODO: respond properly to ended
    private func didReceive(action: MediaPlayerManager._Action) {
        switch action {
        case .stop:
            endPlaybackSession()
            timer.stop()
            cancellables = []
            item = nil
        default: ()
        }
    }

    private func sendStartReport(for item: MediaPlayerItem, seconds: Duration?) {

        #if DEBUG
        guard Defaults[.sendProgressReports] else { return }
        #endif

        Task {
            var info = PlaybackStateInfo()
            info.audioStreamIndex = item.selectedAudioStreamIndex
            info.itemID = item.baseItem.id
            info.liveStreamID = item.mediaSource.liveStreamID
            info.mediaSourceID = item.mediaSource.id
            info.playSessionID = item.playSessionID
            info.positionTicks = seconds?.ticks
            info.sessionID = item.playSessionID
            info.subtitleStreamIndex = item.selectedSubtitleStreamIndex

            let request = Paths.reportPlaybackStart(info)
            try await send(request)

            self.hasSentStart = true
        }
    }

    private func sendStopReport(for item: MediaPlayerItem, seconds: Duration?) {

        #if DEBUG
        guard Defaults[.sendProgressReports] else { return }
        #endif

        Task {
            var info = PlaybackStopInfo()
            info.itemID = item.baseItem.id
            info.liveStreamID = item.mediaSource.liveStreamID
            info.mediaSourceID = item.mediaSource.id
            info.playSessionID = item.playSessionID
            info.positionTicks = seconds?.ticks
            info.sessionID = item.playSessionID

            let request = Paths.reportPlaybackStopped(info)
            try await send(request)
        }
    }

    private func sendProgressReport(for item: MediaPlayerItem, seconds: Duration?, isPaused: Bool = false) {

        #if DEBUG
        guard Defaults[.sendProgressReports] else { return }
        #endif

        Task {
            var info = PlaybackStateInfo()
            info.audioStreamIndex = item.selectedAudioStreamIndex
            info.isPaused = isPaused
            info.itemID = item.baseItem.id
            info.liveStreamID = item.mediaSource.liveStreamID
            info.mediaSourceID = item.mediaSource.id
            info.playSessionID = item.playSessionID
            info.positionTicks = seconds?.ticks
            info.sessionID = item.playSessionID
            info.subtitleStreamIndex = item.selectedSubtitleStreamIndex

            let request = Paths.reportPlaybackProgress(info)
            try await send(request)
        }
    }
}
