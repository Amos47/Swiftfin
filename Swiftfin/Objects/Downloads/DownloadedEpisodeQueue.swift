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

/// Personal fork: the queue while playing a downloaded episode. Next is the next downloaded episode of the series; with
/// none downloaded, it's the server's next episode when the server can be reached.
@MainActor
final class DownloadedEpisodeQueue: ObservableObject, MediaPlayerQueue {

    weak var manager: MediaPlayerManager? {
        didSet {
            cancellables = []
            serverQueue.manager = manager
            guard let manager else { return }

            manager.$playbackItem
                .sink { [weak self] newItem in
                    self?.update(for: newItem?.baseItem)
                }
                .store(in: &cancellables)

            serverQueue.$nextItem
                .sink { [weak self] _ in
                    self?.update(for: self?.manager?.playbackItem?.baseItem)
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

    private func update(for item: BaseItemDto?) {
        guard let itemID = item?.id else {
            nextDownloadedID = nil
            nextItem = nil
            hasNextItem = false
            return
        }

        let episodes = store.episodes(ofSeries: item?.seriesID)
        nextDownloadedID = nextDownloadedEpisode(
            after: itemID,
            in: episodes.map {
                DownloadedEpisode(id: $0.id, season: $0.item.parentIndexNumber ?? 0, episode: $0.item.indexNumber ?? 0)
            }
        )

        if let nextDownloadedID, let record = store.record(for: nextDownloadedID) {
            nextItem = record.playerItemProvider
        } else {
            nextItem = serverQueue.nextItem
        }
        previousItem = serverQueue.previousItem
        hasNextItem = nextItem != nil
        hasPreviousItem = previousItem != nil
    }
}
