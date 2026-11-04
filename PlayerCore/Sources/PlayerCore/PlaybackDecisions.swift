//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

/// Decisions for the Apple (AVPlayer) engine: switching tracks, falling back to VLC, and the one-time settings move.

// MARK: - Track switching

/// What the current stream is. Rendition lists hold Jellyfin stream indexes present in the HLS manifest.
public enum StreamShape: Sendable, Equatable {
    case staticFile
    case hls(subtitleRenditions: [Int], audioRenditions: [Int])
}

public enum TrackSwitch: Sendable, Equatable {
    /// The track is already in the stream; select it without reloading.
    case selectInStream(index: Int)
    case deselectSubtitles
    /// Ask the server for a new stream with this track. `disableDirectPlay` forces an HLS remux of a static file.
    case rebuild(disableDirectPlay: Bool)
}

/// - Parameter index: the Jellyfin subtitle stream index, or -1 for off.
public func subtitleSwitch(to index: Int, isTextSubtitle: Bool, shape: StreamShape) -> TrackSwitch {
    guard index != -1 else { return .deselectSubtitles }

    // Image subtitles are burned in by the server, which always needs a new stream.
    guard isTextSubtitle else { return .rebuild(disableDirectPlay: false) }

    switch shape {
    case .staticFile:
        // A static file has no manifest to carry subtitles, so remux it to HLS.
        return .rebuild(disableDirectPlay: true)
    case let .hls(subtitleRenditions, _):
        return subtitleRenditions.contains(index) ? .selectInStream(index: index) : .rebuild(disableDirectPlay: false)
    }
}

public func audioSwitch(to index: Int, shape: StreamShape) -> TrackSwitch {
    switch shape {
    case .staticFile:
        return .rebuild(disableDirectPlay: false)
    case let .hls(_, audioRenditions):
        return audioRenditions.contains(index) ? .selectInStream(index: index) : .rebuild(disableDirectPlay: false)
    }
}

// MARK: - Fallback

/// With no first frame after this long, and not buffering, the Apple engine is treated as failed.
public let firstFrameTimeout: Double = 15

public enum FallbackDecision: Sendable, Equatable {
    case none
    /// Reload on the Apple engine at the current position.
    case retryApple
    /// Show the error with a "Play with VLC" action.
    case offerVLC
    /// Silently switch this item to VLC.
    case switchToVLC
}

/// Start-up failures switch to VLC. Failures after the first frame, or during Picture in Picture, never switch silently:
/// retry Apple once, then offer VLC.
public func fallbackDecision(
    failed: Bool,
    secondsWithoutFirstFrame: Double,
    isBuffering: Bool,
    hadFirstFrame: Bool,
    alreadyRetried: Bool,
    isPictureInPictureActive: Bool
) -> FallbackDecision {
    if hadFirstFrame || isPictureInPictureActive {
        guard failed else { return .none }
        return alreadyRetried ? .offerVLC : .retryApple
    }

    if failed {
        return .switchToVLC
    }

    if !isBuffering, secondsWithoutFirstFrame >= firstFrameTimeout {
        return .switchToVLC
    }

    return .none
}

// MARK: - Migration

/// Every stored player type moves to the automatic engine once. The household never chose VLC on purpose; it was the
/// default.
public func migratedEngineIsAutomatic(storedPlayerType: String?) -> Bool {
    true
}
