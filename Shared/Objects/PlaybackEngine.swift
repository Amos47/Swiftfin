//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI

// Personal fork: which engine plays video on iOS. Automatic plays on Apple's AVPlayer under Swiftfin's own controls and
// falls back to VLC; tvOS keeps using `VideoPlayerType`.

enum PlaybackEngine: String, CaseIterable, Displayable, Storable {

    case automatic
    case vlc

    var displayTitle: String {
        switch self {
        case .automatic:
            L10n.playbackEngineAutomatic
        case .vlc:
            L10n.playbackEngineVLCOnly
        }
    }

    /// Item IDs that failed on the Apple engine and play on VLC until the player closes.
    nonisolated(unsafe) static var vlcFallbackItemIDs: Set<String> = []

    /// Whether `item` plays on Apple's engine. Live TV and items that fell back stay on VLC.
    static func usesAppleEngine(for item: BaseItemDto) -> Bool {
        #if os(iOS)
        guard Defaults[.VideoPlayer.playbackEngine] == .automatic, !item.isLiveStream else { return false }
        if let id = item.id, vlcFallbackItemIDs.contains(id) {
            return false
        }
        return true
        #else
        return false
        #endif
    }

    /// The device profile family to request for `item`.
    static func playerType(for item: BaseItemDto) -> VideoPlayerType {
        #if os(iOS)
        usesAppleEngine(for: item) ? .native : .swiftfin
        #else
        Defaults[.VideoPlayer.videoPlayerType]
        #endif
    }
}
