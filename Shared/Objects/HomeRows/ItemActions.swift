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

    /// The player's provider and queue for a `play-queue` action on an item page. With `listID` (a film opened from a
    /// list page) the server continues through that list. See `playback(entries:…)`.
    @MainActor
    static func playback(
        item: BaseItemDto,
        action: ItemActionButton,
        listID: String? = nil,
        session: UserSession
    ) async throws -> (provider: MediaPlayerItemProvider, queue: ItemListMediaPlayerQueue) {
        guard let itemID = item.id else { throw ErrorMessage(L10n.unknownError) }
        let entries = try await HomeRowsService.itemActions(for: session).queue(itemID: itemID, actionID: action.id, listID: listID)
        let isTrailer = action.id == ItemActionID.watchTrailer
        let fallback = isTrailer
            ? trailerFallbackTitle(filmTitle: item.name, year: item.productionYear, trailerLabel: L10n.trailer)
            : nil
        return try await playback(
            entries: entries,
            title: isTrailer ? L10n.trailers : action.label,
            film: (id: itemID, fallback: fallback),
            listID: listID,
            session: session
        )
    }

    /// The player's provider and queue for one of a list page's `play-queue` actions (Watch trailers): the whole list.
    @MainActor
    static func playback(
        listID: String,
        action: ItemActionButton,
        session: UserSession
    ) async throws -> (provider: MediaPlayerItemProvider, queue: ItemListMediaPlayerQueue) {
        let entries = try await HomeRowsService.discoveryLists(for: session).queue(listID: listID, actionID: action.id)
        return try await playback(
            entries: entries,
            title: action.id == ItemActionID.watchTrailers ? L10n.trailers : action.label,
            film: nil,
            listID: listID,
            session: session
        )
    }

    /// The server's queue ids, fetched as items in one request and kept in the server's order, leaving out ids the
    /// fetch didn't return (deleted) and items that can't play (`playableQueue`). Each item keeps the server's title
    /// for it; on an older server, trailers whose parent is `film` (the film whose page this is) fall back to its
    /// title. The queue remembers the film it started from (none for a list) and the list, for closing the player.
    /// Throws when nothing in it can play.
    @MainActor
    private static func playback(
        entries: [ItemActionQueueEntry],
        title: String,
        film: (id: String, fallback: QueueItemTitle?)?,
        listID: String?,
        session: UserSession
    ) async throws -> (provider: MediaPlayerItemProvider, queue: ItemListMediaPlayerQueue) {
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

        // The fallback names only trailers of this film; any other item keeps its own title.
        var parentIDs: [String: String] = [:]
        for queued in items {
            if let id = queued.id, let parentID = queued.parentID {
                parentIDs[id] = parentID
            }
        }
        let titles = queueItemTitles(entries: entries, parentIDs: parentIDs, filmID: film?.id, fallback: film?.fallback)

        let queue = ItemListMediaPlayerQueue(
            items: items,
            titles: titles,
            displayTitle: title,
            entries: entries,
            origin: .init(filmID: film?.id, listID: listID)
        )
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

    /// Runs an item page's action. `listID` is the list page the film was opened from, if any.
    func run(
        _ action: ItemActionButton,
        item: BaseItemDto,
        listID: String? = nil,
        route: @escaping @MainActor (MediaPlayerItemProvider, ItemListMediaPlayerQueue) -> Void
    ) {
        guard item.id != nil else { return }
        start(action, route: route) { session in
            try await ItemActionPlayback.playback(item: item, action: action, listID: listID, session: session)
        }
    }

    /// Runs one of a list page's actions (Watch trailers).
    func run(
        _ action: ItemActionButton,
        listID: String,
        route: @escaping @MainActor (MediaPlayerItemProvider, ItemListMediaPlayerQueue) -> Void
    ) {
        start(action, route: route) { session in
            try await ItemActionPlayback.playback(listID: listID, action: action, session: session)
        }
    }

    private func start(
        _ action: ItemActionButton,
        route: @escaping @MainActor (MediaPlayerItemProvider, ItemListMediaPlayerQueue) -> Void,
        playback: @escaping @MainActor (UserSession) async throws -> (provider: MediaPlayerItemProvider, queue: ItemListMediaPlayerQueue)
    ) {
        guard runningActionID == nil,
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
                let playback = try await playback(session)
                guard !Task.isCancelled else { return }
                route(playback.provider, playback.queue)
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Unable to play item action \(action.id): \(error.localizedDescription)")
                let isTrailer = action.id == ItemActionID.watchTrailer || action.id == ItemActionID.watchTrailers
                self.error = ErrorMessage(isTrailer ? L10n.unableToOpenTrailer : L10n.unknownError)
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

// MARK: - Toggle and request actions

/// Personal fork: performs a `toggle` (Save) or `request` (Download) action on an item. A toggle flips at once and
/// rolls back if the server fails; a request waits for the server. Either way the server's returned action replaces
/// it. A request also saves the film on the server, so the item's actions are read again after one; that refresh keeps
/// the on-screen version of any other tap still in flight (`pending`). A success tells Home to rebuild its layout the
/// next time it appears, so a row that was empty (Saved) can show.
enum ItemActionPerformer {

    @MainActor
    static func perform(
        actionID: String,
        itemID: String,
        session: UserSession,
        current: @MainActor () -> [ItemAction],
        pending: @MainActor () -> Set<String>,
        apply: @MainActor ([ItemAction]) -> Void
    ) async throws {
        guard let original = current().first(where: { $0.id == actionID }),
              stateButton(for: original)?.isEnabled == true
        else { return }

        let api = HomeRowsService.itemActions(for: session)
        let guess = optimisticAction(original)
        if let guess {
            apply(replacingAction(guess, in: current()))
        }

        do {
            let updated = try await api.perform(itemID: itemID, actionID: actionID)
            apply(replacingAction(updated, in: current()))
            Notifications[.homeRowsNeedRebuild].post()
        } catch {
            if guess != nil {
                apply(replacingAction(original, in: current()))
            }
            throw error
        }

        if original.kind == ItemActionKind.request {
            let refreshed = await api.actions(itemID: itemID)
            if refreshed.isNotEmpty {
                let others = pending().subtracting([actionID])
                apply(mergingRefreshedActions(refreshed, into: current(), pendingIDs: others))
            }
        }
    }
}

/// Personal fork: the server's actions for the item the player is showing, for its top bar. Reloads when the item
/// changes; a trailer's actions are its film's (Save, Download). Play-queue actions never show here.
@MainActor
final class PlayerServerActions: ObservableObject {

    @Published
    private(set) var actions: ServerItemActions?
    /// Taps in flight, by item, so a late answer for the previous item can't unlock the next item's button.
    @Published
    private(set) var pending: Set<ItemActionPendingKey> = []

    private var loadTask: Task<Void, Never>?
    private let logger = Logger.swiftfin()

    /// The actions for the item on screen, or none while they load (or for another item).
    func actions(for itemID: String?) -> [ItemAction] {
        guard let itemID, let actions, actions.itemID == itemID else { return [] }
        return actions.actions
    }

    /// Whether `actionID`'s tap for `itemID` is still waiting for the server.
    func isPending(_ actionID: String, itemID: String?) -> Bool {
        pendingActionIDs(pending, itemID: itemID).contains(actionID)
    }

    func load(itemID: String?) {
        loadTask?.cancel()
        guard let itemID, let session = Container.shared.currentUserSession() else {
            actions = nil
            return
        }

        let api = HomeRowsService.itemActions(for: session)
        loadTask = Task { [weak self] in
            let actions = await api.actions(itemID: itemID)
            guard !Task.isCancelled else { return }
            self?.actions = ServerItemActions(itemID: itemID, actions: actions)
        }
    }

    func perform(_ button: ItemActionStateButton) {
        guard let itemID = actions?.itemID,
              !isPending(button.id, itemID: itemID),
              let session = Container.shared.currentUserSession()
        else { return }

        let key = ItemActionPendingKey(itemID: itemID, actionID: button.id)
        pending.insert(key)
        Task {
            defer { pending.remove(key) }
            do {
                try await ItemActionPerformer.perform(
                    actionID: button.id,
                    itemID: itemID,
                    session: session,
                    current: { self.actions(for: itemID) },
                    pending: { pendingActionIDs(self.pending, itemID: itemID) },
                    apply: { updated in
                        // The player may have moved on to another item by now.
                        guard self.actions?.itemID == itemID else { return }
                        self.actions = ServerItemActions(itemID: itemID, actions: updated)
                    }
                )
            } catch {
                logger.error("Unable to perform item action \(button.id): \(error.localizedDescription)")
            }
        }
    }
}
