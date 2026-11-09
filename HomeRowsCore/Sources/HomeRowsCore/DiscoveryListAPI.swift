//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

// Personal fork: the fork server's discovery list pages (a series-style page per list) and their actions.

/// One discovery list's page (server `GET Discovery/Lists/{listId}/Page`): the header and the playable films, in list
/// order. The image ids name the items whose backdrop and poster the header shows.
public struct DiscoveryListPage: Decodable, Sendable {

    public let id: String
    public let title: String
    public let overview: String?
    public let backdropItemID: String?
    public let primaryItemID: String?
    public let items: [BaseItemDto]

    public init(
        id: String,
        title: String,
        overview: String? = nil,
        backdropItemID: String? = nil,
        primaryItemID: String? = nil,
        items: [BaseItemDto] = []
    ) {
        self.id = id
        self.title = title
        self.overview = overview
        self.backdropItemID = backdropItemID
        self.primaryItemID = primaryItemID
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case title = "Title"
        case overview = "Overview"
        case backdropItemID = "BackdropItemId"
        case primaryItemID = "PrimaryItemId"
        case items = "Items"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        overview = try nonEmpty(container.decodeIfPresent(String.self, forKey: .overview))
        backdropItemID = try nonEmpty(container.decodeIfPresent(String.self, forKey: .backdropItemID))
        primaryItemID = try nonEmpty(container.decodeIfPresent(String.self, forKey: .primaryItemID))
        items = try container.decodeIfPresent([BaseItemDto].self, forKey: .items) ?? []
    }
}

/// Client for `Discovery/Lists/{listId}/…`, on the same transport as the HomeRows API.
public struct DiscoveryListAPI: Sendable {

    private let transport: HomeRowsTransport

    public init(transport: HomeRowsTransport) {
        self.transport = transport
    }

    /// The list's page. Throws `HomeRowsError.status(404)` for a list the server doesn't know (one that rotated out, or
    /// a server without list pages).
    public func page(listID: String) async throws -> DiscoveryListPage {
        let response = try await transport.send(
            method: "GET",
            path: "Discovery/Lists/\(listID)/Page",
            query: [
                "fields": "PrimaryImageAspectRatio,Overview",
                "enableImageTypes": "Primary,Backdrop,Thumb,Logo",
                "enableUserData": "true",
            ],
            body: nil
        )
        guard (200 ..< 300).contains(response.status) else { throw HomeRowsError.status(response.status) }
        return try HomeRowsAPI.itemsDecoder.decode(DiscoveryListPage.self, from: response.body)
    }

    /// The list's own actions (Watch trailers), in the server's order. Empty on any failure.
    public func actions(listID: String) async -> [ItemAction] {
        await fetchActions(transport: transport, path: "Discovery/Lists/\(listID)/Actions")
    }

    /// The items to play for one of the list's `play-queue` actions: the whole list, in order.
    public func queue(listID: String, actionID: String) async throws -> [ItemActionQueueEntry] {
        try await fetchQueue(transport: transport, path: "Discovery/Lists/\(listID)/Actions/\(actionID)/Queue")
    }
}

/// What a list page's action spot and row show. The first `play-queue` action takes the big spot (Watch trailers); the
/// rest go in the row. Kinds the client doesn't know are left out.
public struct ListPageActions: Equatable, Sendable {
    public let primary: ItemActionButton?
    public let row: [ItemActionButton]
}

public func listPageActions(actions: [ItemAction]) -> ListPageActions {
    let buttons = actionButtons(actions: actions, hasStockTrailers: false).buttons
    return ListPageActions(primary: buttons.first, row: Array(buttons.dropFirst()))
}

/// The film page to open when the player closes: the playing entry's film when it isn't the film the queue started
/// from (`startFilmID`; nil for a queue started from a list page). Nil keeps today's close: the same film, or an entry
/// with no film id (an older server, or an episode queue).
public func closeTarget(startFilmID: String?, currentEntry: ItemActionQueueEntry?) -> String? {
    guard let filmID = currentEntry?.filmID, filmID != startFilmID else { return nil }
    return filmID
}
