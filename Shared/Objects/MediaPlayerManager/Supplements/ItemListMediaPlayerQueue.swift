//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import HomeRowsCore
import JellyfinAPI
import SwiftUI

/// Personal fork: a queue over a fixed list of items, played in order (the server's Watch trailer queue). Next and
/// previous step through the list (`listQueueNeighbours`); every item plays from its start. `titles` holds the player's
/// title per item id (the film a trailer is for); `entries` and `origin` say which film page closing the player opens.
@MainActor
final class ItemListMediaPlayerQueue: ObservableObject, MediaPlayerQueue {

    /// Where the queue was started: the film page (`filmID`) or a list page (`filmID` nil), and the list it runs
    /// through, if any.
    struct Origin {
        let filmID: String?
        let listID: String?
    }

    weak var manager: MediaPlayerManager? {
        didSet {
            cancellables = []
            guard let manager else { return }
            // `item` changes as soon as a new item is picked, so a second Next doesn't replay the one still loading.
            manager.$item
                .sink { [weak self] newItem in
                    self?.update(currentID: newItem.id)
                }
                .store(in: &cancellables)
        }
    }

    let displayTitle: String
    let id: String = "ItemListMediaPlayerQueue"
    let items: [BaseItemDto]
    let titles: [String: QueueItemTitle]
    let origin: Origin
    private let entries: [String: ItemActionQueueEntry]

    @Published
    var nextItem: MediaPlayerItemProvider? = nil
    @Published
    var previousItem: MediaPlayerItemProvider? = nil
    @Published
    var hasNextItem: Bool = false
    @Published
    var hasPreviousItem: Bool = false

    lazy var hasNextItemPublisher: Published<Bool>.Publisher = $hasNextItem
    lazy var hasPreviousItemPublisher: Published<Bool>.Publisher = $hasPreviousItem
    lazy var nextItemPublisher: Published<MediaPlayerItemProvider?>.Publisher = $nextItem
    lazy var previousItemPublisher: Published<MediaPlayerItemProvider?>.Publisher = $previousItem

    private var cancellables: Set<AnyCancellable> = []

    init(
        items: [BaseItemDto],
        titles: [String: QueueItemTitle] = [:],
        displayTitle: String,
        entries: [ItemActionQueueEntry] = [],
        origin: Origin = .init(filmID: nil, listID: nil)
    ) {
        // The same item twice would make Next and the selected row ambiguous.
        var seen: Set<String> = []
        self.items = items.filter { item in
            guard let id = item.id else { return true }
            return seen.insert(id).inserted
        }
        self.titles = titles
        self.displayTitle = displayTitle
        self.origin = origin
        var byID: [String: ItemActionQueueEntry] = [:]
        for entry in entries where byID[entry.id] == nil {
            byID[entry.id] = entry
        }
        self.entries = byID
    }

    func displayTitle(for item: BaseItemDto) -> QueueItemTitle? {
        item.id.flatMap { titles[$0] }
    }

    func closeTarget(for item: BaseItemDto) -> QueueCloseTarget? {
        let entry = item.id.flatMap { entries[$0] }
        return HomeRowsCore.closeTarget(startFilmID: origin.filmID, currentEntry: entry)
            .map { QueueCloseTarget(filmID: $0, listID: origin.listID) }
    }

    var videoPlayerBody: some PlatformView {
        ItemListOverlay(items: items) { [weak self] item in
            guard let self else { return }
            // Tapping the row that's already playing would restart it.
            guard item.id != manager?.item.id else { return }
            manager?.playNewItem(provider: provider(for: item))
        }
    }

    /// The provider that plays `item` from its start, at the player's current bitrate.
    func provider(for item: BaseItemDto) -> MediaPlayerItemProvider {
        MediaPlayerItemProvider(item: item) { [weak self] item, modifyItem in
            let bitrate = await self?.manager?.playbackBitrate ?? Defaults[.VideoPlayer.Playback.appMaximumBitrate]
            return try await MediaPlayerItem.build(for: item, requestedBitrate: bitrate) { item in
                item.userData?.playbackPositionTicks = .zero
                modifyItem?(&item)
            }
        }
    }

    private func update(currentID: String?) {
        let neighbours = listQueueNeighbours(of: currentID, in: items.map { $0.id ?? "" })
        nextItem = neighbours.next.map { provider(for: items[$0]) }
        previousItem = neighbours.previous.map { provider(for: items[$0]) }
        hasNextItem = neighbours.hasNext
        hasPreviousItem = neighbours.hasPrevious
    }
}

extension ItemListMediaPlayerQueue {

    /// The queue's items as a list; the playing one is selected.
    private struct ItemListOverlay: PlatformView {

        @EnvironmentObject
        private var manager: MediaPlayerManager

        let items: [BaseItemDto]
        let action: (BaseItemDto) -> Void

        private var list: some View {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items, id: \.id) { item in
                        ListRow(insets: .init(horizontal: EdgeInsets.edgePadding)) {
                            ZStack {
                                Rectangle()
                                    .fill(.complexSecondary)

                                ImageView(item.imageSource(.primary, environment: ImageSourceOptions(maxWidth: 200)))
                                    .failure {
                                        SystemImageContentView(systemName: item.systemImage)
                                    }
                            }
                            .posterStyle(.landscape)
                            .frame(width: UIDevice.isTV ? 200 : 110)
                            .padding(.vertical, 8)
                        } content: {
                            Text(item.displayTitle)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } action: {
                            action(item)
                        }
                        .isSelected(manager.item.id == item.id)
                    }
                }
            }
        }

        var iOSView: some View {
            list
        }

        var tvOSView: some View {
            list
                .focusSection()
        }
    }
}
