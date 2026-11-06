//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import Foundation
import JellyfinAPI
import UIKit

// Personal fork: playing downloads, with no server needed.

extension MediaPlayerItem {

    /// A player item for a finished download, from its saved metadata and file.
    @MainActor
    static func downloaded(
        _ record: DownloadRecord,
        modifyItem: ((inout BaseItemDto) -> Void)? = nil
    ) throws -> MediaPlayerItem {
        let store = Container.shared.downloadStore()

        guard record.isComplete, let url = store.assetURL(for: record) else {
            throw ErrorMessage(L10n.unableToLoadThisItem)
        }

        var item = record.item
        if item.userData == nil {
            item.userData = UserItemDataDto(key: "")
        }
        if record.localPlayedAt != nil {
            item.userData?.playbackPositionTicks = record.localPositionTicks
        }
        modifyItem?(&item)

        let thumbnailURL = store.imageURL(for: record, image: .thumb)
        let playerItem = MediaPlayerItem(
            baseItem: item,
            mediaSource: downloadedMediaSource(record.mediaSource, url: url),
            playSessionID: UUID().uuidString,
            url: url,
            deviceProfile: DeviceProfile.build(for: .native, compatibilityMode: .auto),
            thumbnailProvider: { UIImage(contentsOfFile: thumbnailURL.path) }
        )
        playerItem.isDownloaded = true
        return playerItem
    }

    /// The media source as it is in the file: one audio track (the default), and only the text subtitles. A
    /// transcoding URL marks it as an HLS stream, so subtitles are picked from the file.
    private static func downloadedMediaSource(_ source: MediaSourceInfo, url: URL) -> MediaSourceInfo {
        var source = source
        let streams = source.mediaStreams ?? []
        let audioIndex = source.defaultAudioStreamIndex ?? streams.first { $0.type == .audio }?.index

        source.mediaStreams = streams.filter { stream in
            switch stream.type {
            case .audio: stream.index == audioIndex
            case .subtitle: stream.isTextSubtitleStream == true
            default: true
            }
        }
        source.defaultAudioStreamIndex = audioIndex
        source.transcodingURL = url.absoluteString
        return source
    }
}

extension DownloadRecord {

    /// A provider that plays this download, as saved when it starts (so it resumes from the latest local position).
    var playerItemProvider: MediaPlayerItemProvider {
        let id = id
        let fallback = self
        return MediaPlayerItemProvider(item: item) { _, modifyItem in
            try await MainActor.run {
                let record = Container.shared.downloadStore().record(for: id) ?? fallback
                return try MediaPlayerItem.downloaded(record, modifyItem: modifyItem)
            }
        }
    }
}
