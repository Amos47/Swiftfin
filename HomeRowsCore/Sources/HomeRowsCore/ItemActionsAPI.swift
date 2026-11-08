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

    /// The item ids to play, in order, for a `play-queue` action.
    public func queue(itemID: String, actionID: String) async throws -> [String] {
        let response = try await transport.send(method: "GET", path: "Items/\(itemID)/Actions/\(actionID)/Queue", query: [:], body: nil)
        guard (200 ..< 300).contains(response.status) else { throw HomeRowsError.status(response.status) }
        guard let ids = try JSONValue.parse(response.body).object?["ItemIds"]?.array else { throw HomeRowsError.invalidResponse }
        return ids.compactMap(\.string)
    }
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
/// trailers, as the user's trailer setting allows); a `watch-trailer` action hides it.
public func actionButtons(actions: [ItemAction], hasStockTrailers: Bool) -> ItemActionPlan {
    let playable = actions.filter { $0.kind == ItemActionKind.playQueue }
    let hasWatchTrailer = playable.contains { $0.id == ItemActionID.watchTrailer }

    return ItemActionPlan(
        buttons: playable.map { ItemActionButton(id: $0.id, label: $0.label, systemImage: actionSystemImage(icon: $0.icon)) },
        showStockTrailers: hasStockTrailers && !hasWatchTrailer
    )
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

/// `items` in the order of `ids`, leaving out ids with no item (and items not in `ids`).
public func orderedByIDs<Item>(_ items: [Item], ids: [String], id: (Item) -> String?) -> [Item] {
    var byID: [String: Item] = [:]
    for item in items {
        if let key = id(item), byID[key] == nil {
            byID[key] = item
        }
    }
    return ids.compactMap { byID[$0] }
}
