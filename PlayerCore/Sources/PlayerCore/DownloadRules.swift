//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Rules for downloads: what stream to ask the server for, how big it will be, what plays next offline, the
/// end-of-episode button and whether offline progress goes back to the server.

public enum DownloadQuality: String, CaseIterable, Sendable {
    /// About 1 GB an hour.
    case standard
    /// About 2.3 GB an hour.
    case higher

    public var videoBitrate: Int {
        switch self {
        case .standard: 2_000_000
        case .higher: 5_000_000
        }
    }

    public var audioBitrate: Int {
        switch self {
        case .standard: 128_000
        case .higher: 192_000
        }
    }
}

public struct DownloadStreamRequest: Equatable, Sendable {

    /// Whether the server copies the video as-is, rather than shrinking it.
    public let copiesVideo: Bool
    public let videoBitrate: Int
    public let audioBitrate: Int
    /// The server's `VideoCodec` list: a copy keeps HEVC or H.264; a shrunk stream is H.264, which servers without a
    /// GPU encoder make fast enough for the downloader (a slow HEVC encode makes the server restart and drop segments).
    public let videoCodecs: String
    /// The text subtitle to request so the stream lists all text subtitles; nil leaves subtitles out of the request.
    public let subtitleStreamIndex: Int?
}

/// Asking for a bitrate this far above the source makes the server copy the video instead of re-encoding it.
let copyVideoBitrate = 40_000_000

private let copyableVideoCodecs: Set<String> = ["hevc", "h264"]

/// The stream to download. A source the Apple player can play that is already within the quality's bitrate is copied
/// (full quality, smallest, fastest); anything else is shrunk to the quality's bitrates.
public func downloadStreamRequest(
    sourceVideoCodec: String?,
    sourceVideoBitrate: Int?,
    firstTextSubtitleIndex: Int?,
    quality: DownloadQuality
) -> DownloadStreamRequest {
    let copies = if let codec = sourceVideoCodec?.lowercased(), copyableVideoCodecs.contains(codec),
                    let bitrate = sourceVideoBitrate
    {
        bitrate <= quality.videoBitrate
    } else {
        false
    }

    return DownloadStreamRequest(
        copiesVideo: copies,
        videoBitrate: copies ? copyVideoBitrate : quality.videoBitrate,
        audioBitrate: quality.audioBitrate,
        videoCodecs: copies ? "hevc,h264" : "h264",
        subtitleStreamIndex: firstTextSubtitleIndex
    )
}

/// Roughly how many bytes the download takes: the source's bitrate when copied, else the requested bitrates.
public func estimatedDownloadBytes(_ request: DownloadStreamRequest, sourceBitrate: Int?, runtimeSeconds: Double) -> Int64 {
    let bitsPerSecond = if request.copiesVideo, let sourceBitrate {
        Double(sourceBitrate)
    } else {
        Double(request.videoBitrate + request.audioBitrate)
    }
    return Int64(bitsPerSecond * runtimeSeconds / 8)
}

public struct DownloadedEpisode: Equatable, Sendable {

    public let id: String
    public let season: Int
    public let episode: Int

    public init(id: String, season: Int, episode: Int) {
        self.id = id
        self.season = season
        self.episode = episode
    }
}

/// The downloaded episode after `id` in season and episode order, skipping any that aren't downloaded.
public func nextDownloadedEpisode(after id: String, in episodes: [DownloadedEpisode]) -> String? {
    let ordered = episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    guard let index = ordered.firstIndex(where: { $0.id == id }), index + 1 < ordered.count else { return nil }
    return ordered[index + 1].id
}

public enum DownloadEndAction: Equatable, Sendable {
    /// Delete the finished download and play the next downloaded episode.
    case nextAndDelete(nextID: String)
    /// Delete the finished download and close the player.
    case delete
}

/// The extra button a download gets at the moment Next Episode would show (credits, or near the end).
public func downloadEndAction(isDownloaded: Bool, atNextEpisodeMoment: Bool, nextDownloadedID: String?) -> DownloadEndAction? {
    guard isDownloaded, atNextEpisodeMoment else { return nil }
    if let nextDownloadedID {
        return .nextAndDelete(nextID: nextDownloadedID)
    }
    return .delete
}

public enum ProgressSyncDecision: Equatable, Sendable {
    case sendLocal
    case keepServer
}

/// Offline progress goes to the server only when it was made after the download and is newer than the server's.
public func progressSyncDecision(localPlayedAt: Date?, downloadedAt: Date, serverLastPlayed: Date?) -> ProgressSyncDecision {
    guard let localPlayedAt, localPlayedAt > downloadedAt else { return .keepServer }
    if let serverLastPlayed, serverLastPlayed >= localPlayedAt {
        return .keepServer
    }
    return .sendLocal
}

/// Where a downloaded asset lives, relative to the app's home folder, which changes between installs. iOS puts assets
/// under `Library/`; the simulator reports the path with a `/.nofollow` prefix, so it's cut at the last `/Library/`.
public func downloadAssetRelativePath(_ absolutePath: String) -> String? {
    guard let range = absolutePath.range(of: "/Library/", options: .backwards) else { return nil }
    return String(absolutePath[absolutePath.index(after: range.lowerBound)...])
}

// MARK: - Queue

/// A download waiting to start, in queue order.
public struct QueuedDownload: Equatable, Sendable {

    public let id: String
    public let copiesVideo: Bool

    public init(id: String, copiesVideo: Bool) {
        self.id = id
        self.copiesVideo = copiesVideo
    }
}

/// A download running or starting.
public struct RunningDownload: Equatable, Sendable {

    public let id: String
    public let copiesVideo: Bool

    public init(id: String, copiesVideo: Bool) {
        self.id = id
        self.copiesVideo = copiesVideo
    }
}

/// At most this many downloads run at once on one phone.
public let maxConcurrentDownloads = 3

/// The queued downloads to start now, in queue order. A download the server has to shrink runs one at a time (it's
/// the slow, server-heavy kind); copies fill the rest, up to `maxConcurrentDownloads`.
public func downloadsToStart(queued: [QueuedDownload], running: [RunningDownload]) -> [String] {
    var count = running.count
    var shrinking = running.contains { !$0.copiesVideo }
    var start: [String] = []

    for download in queued where count < maxConcurrentDownloads {
        if !download.copiesVideo {
            guard !shrinking else { continue }
            shrinking = true
        }
        start.append(download.id)
        count += 1
    }
    return start
}

public enum DownloadFinishOutcome: Equatable, Sendable {
    case complete
    /// Shows Retry.
    case failed
    /// The user cancelled it; its record is already gone.
    case ignore
}

/// What a finished download task means. Only a cancel the user asked for is ignored: the system cancels downloads on a
/// force quit, and those get Retry.
public func downloadFinishOutcome(failed: Bool, cancelled: Bool, cancelRequested: Bool, playableOffline: Bool) -> DownloadFinishOutcome {
    if cancelled, cancelRequested {
        return .ignore
    }
    if failed || !playableOffline {
        return .failed
    }
    return .complete
}

// MARK: - Progress

/// Offline progress kept after its download is deleted, until the server has it.
public struct PendingProgress: Codable, Equatable, Sendable {

    public let id: String
    public let positionTicks: Int
    public let played: Bool
    public let playedAt: Date
    public let downloadedAt: Date

    public init(id: String, positionTicks: Int, played: Bool, playedAt: Date, downloadedAt: Date) {
        self.id = id
        self.positionTicks = positionTicks
        self.played = played
        self.playedAt = playedAt
        self.downloadedAt = downloadedAt
    }
}

/// Adds `progress`, keeping only the latest entry per item.
public func addingPendingProgress(_ progress: PendingProgress, to list: [PendingProgress]) -> [PendingProgress] {
    if let existing = list.first(where: { $0.id == progress.id }), existing.playedAt >= progress.playedAt {
        return list
    }
    return list.filter { $0.id != progress.id } + [progress]
}

public enum ResumeSource: Equatable, Sendable {
    case local
    case server
}

/// Where a download resumes from: whichever of the offline and the server position was watched last.
public func resumeSource(localPlayedAt: Date?, serverLastPlayed: Date?) -> ResumeSource {
    guard let localPlayedAt else { return .server }
    guard let serverLastPlayed else { return .local }
    return serverLastPlayed > localPlayedAt ? .server : .local
}
