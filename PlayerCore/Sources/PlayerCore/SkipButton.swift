//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

/// Which skip or Next Episode button the player shows. All times are seconds.

public enum SkipKind: Sendable, Equatable {
    case intro
    case recap
    case outro
    case preview
}

public struct SkipSegment: Sendable, Equatable {

    public let kind: SkipKind
    public let start: Double
    public let end: Double

    public init(kind: SkipKind, start: Double, end: Double) {
        self.kind = kind
        self.start = start
        self.end = end
    }
}

public enum SkipButton: Sendable, Equatable {
    /// Seeks to `to`, the segment's end.
    case skip(SkipKind, to: Double, prominent: Bool)
    case nextEpisode(prominent: Bool)
}

/// How long a button stays prominent after playback enters its segment.
public let skipProminentDuration: Double = 8

/// Without an outro segment, Next Episode shows this close to the end.
public let nextEpisodeFallbackWindow: Double = 30

/// The button to show at `position`. It shows anywhere inside a segment, so resuming or seeking into one still offers it.
///
/// - Parameter enteredSegmentAt: where playback first entered the current segment; nil means it just did.
public func skipButton(
    position: Double,
    runtime: Double?,
    segments: [SkipSegment],
    hasNextItem: Bool,
    isLive: Bool,
    enteredSegmentAt: Double?
) -> SkipButton? {
    guard !isLive else { return nil }

    let current = segments
        .filter { $0.start <= position && position < $0.end }
        .max { $0.start < $1.start }

    if let current {
        let prominent = position - (enteredSegmentAt ?? position) < skipProminentDuration
        if current.kind == .outro, hasNextItem {
            return .nextEpisode(prominent: prominent)
        }
        return .skip(current.kind, to: current.end, prominent: prominent)
    }

    let hasOutro = segments.contains { $0.kind == .outro }
    if hasNextItem, !hasOutro, let runtime, runtime - position <= nextEpisodeFallbackWindow {
        return .nextEpisode(prominent: true)
    }

    return nil
}

/// What the player's Next button says.
public enum NextButtonLabel: Sendable, Equatable {
    case nextEpisode
    case next
}

/// "Next Episode" only when the next queue item is an episode; trailers and other lists say "Next".
public func nextButtonLabel(nextItemIsEpisode: Bool) -> NextButtonLabel {
    nextItemIsEpisode ? .nextEpisode : .next
}
