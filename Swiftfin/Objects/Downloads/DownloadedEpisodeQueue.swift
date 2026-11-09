//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import FactoryKit
import JellyfinAPI
import PlayerCore
import SwiftUI

/// Personal fork: the queue while playing a downloaded episode. Next and Previous are the next and previous downloaded
/// episodes of the series; with none downloaded on that side, the server's episode when the server can be reached.
@MainActor
final class DownloadedEpisodeQueue: ObservableObject, MediaPlayerQueue {

    weak var manager: MediaPlayerManager? {
        didSet {
            cancellables = []
            serverQueue.manager = manager
            guard let manager else { return }

            // Built from the emitted values: `@Published` emits before the property changes, so reading
            // `serverQueue.nextItem` or `manager.playbackItem` inside the sink would see the old ones.
            manager.$playbackItem
                .combineLatest(serverQueue.$nextItem, serverQueue.$previousItem)
                .sink { [weak self] playbackItem, serverNext, serverPrevious in
                    self?.update(for: playbackItem?.baseItem, serverNext: serverNext, serverPrevious: serverPrevious)
                }
                .store(in: &cancellables)
        }
    }

    let displayTitle: String = L10n.episodes
    let id: String = "DownloadedEpisodeQueue"

    @Published
    var nextItem: MediaPlayerItemProvider? = nil
    @Published
    var previousItem: MediaPlayerItemProvider? = nil
    @Published
    var hasNextItem: Bool = false
    @Published
    var hasPreviousItem: Bool = false

    /// The next downloaded episode, for Next & delete.
    @Published
    private(set) var nextDownloadedID: String?

    lazy var hasNextItemPublisher: Published<Bool>.Publisher = $hasNextItem
    lazy var hasPreviousItemPublisher: Published<Bool>.Publisher = $hasPreviousItem
    lazy var nextItemPublisher: Published<MediaPlayerItemProvider?>.Publisher = $nextItem
    lazy var previousItemPublisher: Published<MediaPlayerItemProvider?>.Publisher = $previousItem

    @Injected(\.downloadStore)
    private var store: DownloadStore

    private let serverQueue: EpisodeMediaPlayerQueue
    private var cancellables: Set<AnyCancellable> = []

    init(episode: BaseItemDto) {
        self.serverQueue = EpisodeMediaPlayerQueue(episode: episode)
    }

    var videoPlayerBody: some PlatformView {
        serverQueue.videoPlayerBody
    }

    /// Next and Previous prefer a downloaded episode on that side (it plays offline); otherwise the server's.
    private func update(for item: BaseItemDto?, serverNext: MediaPlayerItemProvider?, serverPrevious: MediaPlayerItemProvider?) {
        guard let itemID = item?.id else {
            nextDownloadedID = nil
            nextItem = nil
            previousItem = nil
            hasNextItem = false
            hasPreviousItem = false
            return
        }

        let episodes = store.episodes(ofSeries: item?.seriesID).map {
            DownloadedEpisode(id: $0.id, season: $0.item.parentIndexNumber ?? 0, episode: $0.item.indexNumber ?? 0)
        }
        nextDownloadedID = nextDownloadedEpisode(after: itemID, in: episodes)

        nextItem = provider(
            for: downloadedQueueSide(downloadedID: nextDownloadedID, hasServerItem: serverNext != nil),
            server: serverNext
        )
        previousItem = provider(
            for: downloadedQueueSide(
                downloadedID: previousDownloadedEpisode(before: itemID, in: episodes),
                hasServerItem: serverPrevious != nil
            ),
            server: serverPrevious
        )
        hasNextItem = nextItem != nil
        hasPreviousItem = previousItem != nil
    }

    private func provider(for side: DownloadedQueueSide, server: MediaPlayerItemProvider?) -> MediaPlayerItemProvider? {
        switch side {
        case let .downloaded(id):
            // A record that's gone since the list was read falls back to the server's episode.
            store.record(for: id)?.playerItemProvider ?? server
        case .server:
            server
        case .none:
            nil
        }
    }
}
