//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

// Personal fork: item actions (like Watch trailer) offered by the fork server on an item page.

/// One action the server offers on an item. `kind` says how a client runs it; clients ignore kinds they don't know.
public struct ItemAction: Equatable, Sendable {

    public let id: String
    public let label: String
    public let icon: String?
    public let kind: String

    public init(id: String, label: String, icon: String?, kind: String) {
        self.id = id
        self.label = label
        self.icon = icon
        self.kind = kind
    }
}

/// Client for `Items/{id}/Actions`, on the same transport as the HomeRows API.
public struct ItemActionsAPI: Sendable {

    private let transport: HomeRowsTransport

    public init(transport: HomeRowsTransport) {
        self.transport = transport
    }

    /// The item's actions, in the server's order. Empty on a 404 (a stock server, or an item the user can't see) and on
    /// any other failure, so a page never shows an error for them.
    public func actions(itemID: String) async -> [ItemAction] {
        guard let response = try? await transport.send(method: "GET", path: "Items/\(itemID)/Actions", query: [:], body: nil),
              (200 ..< 300).contains(response.status),
              let entries = (try? JSONValue.parse(response.body))?.array
        else { return [] }

        return entries.compactMap { entry in
            guard let object = entry.object,
                  let id = object["Id"]?.string,
                  let kind = object["Kind"]?.string
            else { return nil }
            return ItemAction(id: id, label: object["Label"]?.string ?? id, icon: object["Icon"]?.string, kind: kind)
        }
    }

    /// The items to play, in order, for a `play-queue` action. `ItemIds` gives the order; the newer `Items` field adds a
    /// title and subtitle per id. An older server sends only `ItemIds`, so the entries have no titles; a response with
    /// only `Items` uses its order.
    public func queue(itemID: String, actionID: String) async throws -> [ItemActionQueueEntry] {
        let response = try await transport.send(method: "GET", path: "Items/\(itemID)/Actions/\(actionID)/Queue", query: [:], body: nil)
        guard (200 ..< 300).contains(response.status) else { throw HomeRowsError.status(response.status) }
        guard let object = try JSONValue.parse(response.body).object else { throw HomeRowsError.invalidResponse }

        let items: [ItemActionQueueEntry] = (object["Items"]?.array ?? []).compactMap { value in
            guard let entry = value.object, let id = entry["Id"]?.string else { return nil }
            return ItemActionQueueEntry(id: id, title: nonEmpty(entry["Title"]?.string), subtitle: nonEmpty(entry["Subtitle"]?.string))
        }

        guard let ids = object["ItemIds"]?.array?.compactMap(\.string) else {
            guard object["Items"]?.array != nil else { throw HomeRowsError.invalidResponse }
            return items
        }

        var byID: [String: ItemActionQueueEntry] = [:]
        for item in items where byID[item.id] == nil {
            byID[item.id] = item
        }
        return ids.map { byID[$0] ?? ItemActionQueueEntry(id: $0, title: nil, subtitle: nil) }
    }
}

private func nonEmpty(_ string: String?) -> String? {
    guard let string, !string.isEmpty else { return nil }
    return string
}

/// One item of a server queue, with the title and subtitle the player shows for it when the server names it.
public struct ItemActionQueueEntry: Equatable, Sendable {

    public let id: String
    public let title: String?
    public let subtitle: String?

    public init(id: String, title: String?, subtitle: String?) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

/// The player's top-left title (and the line under it) for a queue item.
public struct QueueItemTitle: Equatable, Sendable {

    public let title: String
    public let subtitle: String?

    public init(title: String, subtitle: String?) {
        self.title = title
        self.subtitle = subtitle
    }
}

/// The server's title for `entry` (with its subtitle, if any); without one, `fallback`; nil means the player's own title.
public func queueItemTitle(entry: ItemActionQueueEntry, fallback: QueueItemTitle?) -> QueueItemTitle? {
    if let title = entry.title {
        return QueueItemTitle(title: title, subtitle: entry.subtitle)
    }
    return fallback
}

/// The player's title per queue item id: the server's title when it names the item; otherwise `fallback`, but only
/// for an item whose parent (`parentIDs`) is the page's film (`filmID`). Every other item keeps the player's own title,
/// so it has no entry.
public func queueItemTitles(
    entries: [ItemActionQueueEntry],
    parentIDs: [String: String],
    filmID: String?,
    fallback: QueueItemTitle?
) -> [String: QueueItemTitle] {
    var titles: [String: QueueItemTitle] = [:]
    for entry in entries where titles[entry.id] == nil {
        let isOfFilm = filmID != nil && parentIDs[entry.id] == filmID
        if let title = queueItemTitle(entry: entry, fallback: isOfFilm ? fallback : nil) {
            titles[entry.id] = title
        }
    }
    return titles
}

/// For an older server, the trailer queue's title: the film the page is for, "Trailer · year" under it. Nil without a
/// film title.
public func trailerFallbackTitle(filmTitle: String?, year: Int?, trailerLabel: String) -> QueueItemTitle? {
    guard let filmTitle = nonEmpty(filmTitle) else { return nil }
    return QueueItemTitle(title: filmTitle, subtitle: year.map { "\(trailerLabel) · \($0)" } ?? trailerLabel)
}

// MARK: - Plan

public enum ItemActionKind {
    public static let playQueue = "play-queue"
}

public enum ItemActionID {
    public static let watchTrailer = "watch-trailer"
}

/// A button for one server action.
public struct ItemActionButton: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let systemImage: String
}

/// What the item page's action row shows for the server's actions.
public struct ItemActionPlan: Equatable, Sendable {

    /// One per `play-queue` action, in the server's order.
    public let buttons: [ItemActionButton]
    /// Whether the stock Trailers button (local and external trailers) still shows. Watch trailer replaces it, so the
    /// page has one trailer button.
    public let showStockTrailers: Bool
}

/// The buttons for `actions`. `hasStockTrailers` is whether the stock Trailers button would show (local or external
/// trailers, as the user's trailer setting allows); a `watch-trailer` action hides it. With `watchTrailerInPlaySpot`
/// the big Play spot shows Watch trailer, so the row leaves it out and the page still has one trailer button.
public func actionButtons(actions: [ItemAction], hasStockTrailers: Bool, watchTrailerInPlaySpot: Bool = false) -> ItemActionPlan {
    let playable = actions.filter { $0.kind == ItemActionKind.playQueue }
    let hasWatchTrailer = playable.contains { $0.id == ItemActionID.watchTrailer }
    let inRow = watchTrailerInPlaySpot ? playable.filter { $0.id != ItemActionID.watchTrailer } : playable

    return ItemActionPlan(
        buttons: inRow.map(ItemActionButton.init),
        showStockTrailers: hasStockTrailers && !hasWatchTrailer
    )
}

/// The `watch-trailer` play-queue action as a button, when the server offers one.
public func watchTrailerButton(actions: [ItemAction]) -> ItemActionButton? {
    actions
        .first { $0.kind == ItemActionKind.playQueue && $0.id == ItemActionID.watchTrailer }
        .map(ItemActionButton.init)
}

/// The Watch trailer action when it takes an item page's Play spot: only for an item that isn't playable and has no
/// playback provider (a season with no folder is reported Virtual but is owned and plays), and only when the server
/// offers `watch-trailer`. Otherwise nil, and Watch trailer (if any) stays in the action row.
public func playSpotAction(isPlayable: Bool, hasPlaybackProvider: Bool, actions: [ItemAction]) -> ItemActionButton? {
    guard !isPlayable, !hasPlaybackProvider else { return nil }
    return watchTrailerButton(actions: actions)
}

extension ItemActionButton {
    init(_ action: ItemAction) {
        self.init(id: action.id, label: action.label, systemImage: actionSystemImage(icon: action.icon))
    }
}

/// What the big Play spot on an item page shows.
public enum PlaySpot: Equatable, Sendable {
    /// The stock Play button (unchanged).
    case play
    /// The server's Watch trailer action, for a film the user doesn't have.
    case watchTrailer
    /// A grey, disabled "Not in your library".
    case notInLibrary
}

/// `.play` when the item can be played; otherwise `.watchTrailer` when the server offers `watch-trailer`; otherwise
/// `.notInLibrary` (a stock server, or one with no trailer for the film).
public func playSpot(isPlayable: Bool, hasWatchTrailer: Bool) -> PlaySpot {
    if isPlayable {
        return .play
    }
    return hasWatchTrailer ? .watchTrailer : .notInLibrary
}

/// The SF Symbol for a server icon name.
public func actionSystemImage(icon: String?) -> String {
    switch icon {
    case "trailer": "film"
    default: "play.fill"
    }
}

// MARK: - List queue

/// The indices of the items before and after the current one in a fixed play list.
public struct ListQueueNeighbours: Equatable, Sendable {

    public let previous: Int?
    public let next: Int?

    public var hasPrevious: Bool {
        previous != nil
    }

    public var hasNext: Bool {
        next != nil
    }
}

/// The neighbours of `currentID` in `ids`. An id that isn't in the list (or none) has neither.
public func listQueueNeighbours(of currentID: String?, in ids: [String]) -> ListQueueNeighbours {
    guard let currentID, let index = ids.firstIndex(of: currentID) else {
        return ListQueueNeighbours(previous: nil, next: nil)
    }
    return ListQueueNeighbours(
        previous: index > 0 ? index - 1 : nil,
        next: index + 1 < ids.count ? index + 1 : nil
    )
}

/// `items` in the order of `ids`, leaving out ids with no item (and items not in `ids`). An id listed twice
/// gives its item once, at the first position.
public func orderedByIDs<Item>(_ items: [Item], ids: [String], id: (Item) -> String?) -> [Item] {
    var byID: [String: Item] = [:]
    for item in items {
        if let key = id(item), byID[key] == nil {
            byID[key] = item
        }
    }
    var seen: Set<String> = []
    return ids.compactMap { seen.insert($0).inserted ? byID[$0] : nil }
}
