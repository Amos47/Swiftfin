//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

#if os(iOS)
import PlayerCore
#endif

// Personal fork: track switching on the Apple (AVPlayer) engine.

extension MediaPlayerItem {

    /// Jellyfin indexes of the source's text subtitles, in source order. Jellyfin lists them in this order in an HLS
    /// manifest once a subtitle was requested over HLS.
    var textSubtitleStreamIndexes: [Int] {
        (mediaSource.mediaStreams ?? [])
            .filter { $0.type == .subtitle && $0.isTextSubtitleStream == true }
            .compactMap(\.index)
    }

    #if os(iOS)
    /// What the current stream carries: a static file, or HLS with subtitle renditions when they were requested over HLS.
    var streamShape: StreamShape {
        guard let transcodingURL = mediaSource.transcodingURL else { return .staticFile }
        let hasSubtitleRenditions = transcodingURL.localizedCaseInsensitiveContains("SubtitleMethod=Hls")
        return .hls(subtitleRenditions: hasSubtitleRenditions ? textSubtitleStreamIndexes : [], audioRenditions: [])
    }

    func appleTrackSwitch(type: MediaStreamType, from oldIndex: Int?, to newIndex: Int) -> TrackSwitch? {
        switch type {
        case .subtitle:
            let oldStream = oldIndex.flatMap { index in subtitleStreams.first { $0.index == index } }
            let newStream = subtitleStreams.first { $0.index == newIndex }
            return subtitleSwitch(
                to: newIndex,
                isTextSubtitle: newStream?.isTextSubtitleStream ?? true,
                shape: streamShape,
                fromBurnedIn: oldStream.map { $0.isTextSubtitleStream != true } ?? false
            )
        case .audio:
            return audioSwitch(to: newIndex, shape: streamShape)
        default:
            return nil
        }
    }
    #endif
}
