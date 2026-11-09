//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import HomeRowsCore
import JellyfinAPI

@MainActor
protocol MediaPlayerQueue: ObservableObject, MediaPlayerObserver, MediaPlayerSupplement {

    var hasNextItem: Bool { get }
    var hasPreviousItem: Bool { get }

    var nextItem: MediaPlayerItemProvider? { get }
    var previousItem: MediaPlayerItemProvider? { get }

    var hasNextItemPublisher: Published<Bool>.Publisher { get set }
    var hasPreviousItemPublisher: Published<Bool>.Publisher { get set }
    var nextItemPublisher: Published<MediaPlayerItemProvider?>.Publisher { get set }
    var previousItemPublisher: Published<MediaPlayerItemProvider?>.Publisher { get set }

    /// Personal fork: the player's title for `item` when the queue knows a better one (a trailer queue names the
    /// film). Nil keeps the player's own title.
    func displayTitle(for item: BaseItemDto) -> QueueItemTitle?
}

extension MediaPlayerQueue {

    func displayTitle(for item: BaseItemDto) -> QueueItemTitle? {
        nil
    }

    var hasNextItem: Bool {
        nextItem != nil
    }

    var hasPreviousItem: Bool {
        previousItem != nil
    }
}

class AnyMediaPlayerQueue: MediaPlayerQueue {

    @Published
    var hasNextItem: Bool
    @Published
    var hasPreviousItem: Bool

    @Published
    var nextItem: MediaPlayerItemProvider?
    @Published
    var previousItem: MediaPlayerItemProvider?

    lazy var hasNextItemPublisher: Published<Bool>.Publisher = $hasNextItem
    lazy var hasPreviousItemPublisher: Published<Bool>.Publisher = $hasPreviousItem
    lazy var nextItemPublisher: Published<MediaPlayerItemProvider?>.Publisher = $nextItem
    lazy var previousItemPublisher: Published<MediaPlayerItemProvider?>.Publisher = $previousItem

    private var wrapped: any MediaPlayerQueue

    var displayTitle: String {
        wrapped.displayTitle
    }

    var id: String {
        wrapped.id
    }

    func displayTitle(for item: BaseItemDto) -> QueueItemTitle? {
        wrapped.displayTitle(for: item)
    }

    weak var manager: MediaPlayerManager? {
        get { wrapped.manager }
        set { wrapped.manager = newValue }
    }

    private var cancellables: [AnyCancellable] = []

    init(_ wrapped: some MediaPlayerQueue) {
        self.wrapped = wrapped
        self.hasNextItem = wrapped.hasNextItem
        self.hasPreviousItem = wrapped.hasPreviousItem

        wrapped.hasNextItemPublisher
            .assign(to: &$hasNextItem)
        wrapped.hasPreviousItemPublisher
            .assign(to: &$hasPreviousItem)
        wrapped.nextItemPublisher
            .assign(to: &$nextItem)
        wrapped.previousItemPublisher
            .assign(to: &$previousItem)
    }

    var videoPlayerBody: some PlatformView {
        wrapped
            .videoPlayerBody
            .eraseToAnyView()
    }
}

extension BaseItemDto {

    /// Personal fork: what Previous and Next need to know to skip this item (`isValidQueueTarget`). Media sources
    /// count only when they were fetched.
    var queueCandidate: QueueCandidate {
        QueueCandidate(id: id ?? "", isMissing: isMissing, isUnaired: isUnaired, hasMedia: mediaSources.map(\.isNotEmpty))
    }
}
