//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import Foundation
import HomeRowsCore
import JellyfinAPI
import Logging

// Personal fork: the fork server's item actions (Watch trailer) on an item page.

/// The server's answer for one item's actions. A failure (a stock server's 404 included) is an empty answer.
struct ServerItemActions: Equatable {
    let itemID: String?
    let actions: [ItemAction]
}

enum ItemActionPlayback {

    /// The player's provider and queue for a `play-queue` action: the server's queue ids, fetched as items in one
    /// request and kept in the server's order, leaving out ids the fetch didn't return (deleted) and items that can't
    /// play (`playableQueue`). Each item keeps the server's title for it; an older server's trailers fall back to
    /// `item`'s name (the film whose page this is). Throws when the queue fails or nothing in it can play.
    @MainActor
    static func playback(
        item: BaseItemDto,
        action: ItemActionButton,
        session: UserSession
    ) async throws -> (provider: MediaPlayerItemProvider, queue: ItemListMediaPlayerQueue) {
        guard let itemID = item.id else { throw ErrorMessage(L10n.unknownError) }
        let entries = try await HomeRowsService.itemActions(for: session).queue(itemID: itemID, actionID: action.id)
        let ids = entries.map(\.id)
        guard ids.isNotEmpty else { throw ErrorMessage(L10n.unknownError) }

        var parameters = Paths.GetItemsParameters()
        parameters.userID = session.user.id
        parameters.ids = ids
        parameters.fields = .MinimumFields
        parameters.enableUserData = true
        let response = try await session.client.send(Paths.getItems(parameters: parameters))
        // A trailer carries its film's premiere date, so a future date doesn't make it unplayable here.
        let items = playableQueue(ids: ids, fetched: response.value.items ?? []) { item in
            item.id.map { QueueCandidate(id: $0, isMissing: item.isMissing, isUnaired: false, hasMedia: item.queueCandidate.hasMedia) }
        }

        guard let first = items.first else { throw ErrorMessage(L10n.unknownError) }

        let isTrailer = action.id == ItemActionID.watchTrailer
        let fallback = isTrailer
            ? trailerFallbackTitle(filmTitle: item.name, year: item.productionYear, trailerLabel: L10n.trailer)
            : nil
        var titles: [String: QueueItemTitle] = [:]
        for entry in entries {
            titles[entry.id] = titles[entry.id] ?? queueItemTitle(entry: entry, fallback: fallback)
        }

        let title = isTrailer ? L10n.trailers : action.label
        let queue = ItemListMediaPlayerQueue(items: items, titles: titles, displayTitle: title)
        return (queue.provider(for: first), queue)
    }
}

/// Runs a server action's queue for one view: the item page's Play spot (Watch trailer) and its action row share this,
/// so both take the same path. Taps while one is loading are ignored; `cancel()` (on disappear) drops a loading queue
/// so no player opens over whatever is on screen by then.
@MainActor
final class ItemActionRunner: ObservableObject {

    @Published
    private(set) var runningActionID: String?
    @Published
    var error: Error?

    private var task: Task<Void, Never>?
    private var runCount = 0
    private let logger = Logger.swiftfin()

    var isRunning: Bool {
        runningActionID != nil
    }

    func run(
        _ action: ItemActionButton,
        item: BaseItemDto,
        route: @escaping @MainActor (MediaPlayerItemProvider, ItemListMediaPlayerQueue) -> Void
    ) {
        guard runningActionID == nil,
              item.id != nil,
              let session = Container.shared.currentUserSession()
        else { return }

        runCount += 1
        let run = runCount
        runningActionID = action.id
        task = Task {
            defer {
                if run == self.runCount {
                    self.runningActionID = nil
                    self.task = nil
                }
            }
            do {
                let playback = try await ItemActionPlayback.playback(item: item, action: action, session: session)
                guard !Task.isCancelled else { return }
                route(playback.provider, playback.queue)
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Unable to play item action \(action.id): \(error.localizedDescription)")
                self.error = ErrorMessage(action.id == ItemActionID.watchTrailer ? L10n.unableToOpenTrailer : L10n.unknownError)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        runningActionID = nil
        runCount += 1
    }
}
