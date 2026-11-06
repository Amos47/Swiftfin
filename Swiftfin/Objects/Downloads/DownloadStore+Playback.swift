//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI

// Personal fork: downloaded items play from the file wherever they're started.

extension DownloadStore {

    /// The provider and queue for a finished download of `item`, or nil when it isn't downloaded.
    func downloadedPlayback(
        for item: BaseItemDto,
        fromBeginning: Bool
    ) -> (provider: MediaPlayerItemProvider, queue: (any MediaPlayerQueue)?)? {
        guard let record = record(for: item.id), record.isComplete else { return nil }

        var provider = record.playerItemProvider
        if fromBeginning {
            provider = provider.modifyingItem { $0.userData?.playbackPositionTicks = 0 }
        }
        let queue: (any MediaPlayerQueue)? = record.item.type == .episode ? DownloadedEpisodeQueue(episode: record.item) : nil
        return (provider, queue)
    }

    /// For a series or season that can't be resolved (no server), its first downloaded episode not yet watched offline.
    func firstDownloadedEpisode(of item: BaseItemDto) -> BaseItemDto? {
        let seriesID = item.type == .series ? item.id : item.seriesID
        let episodes = episodes(ofSeries: seriesID).filter { item.type != .season || $0.item.seasonID == item.id }
        return (episodes.first { !$0.localPlayed } ?? episodes.first)?.item
    }
}
