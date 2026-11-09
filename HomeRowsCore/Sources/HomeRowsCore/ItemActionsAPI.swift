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
    /// The current state of a `toggle` (`on`/`off`) or `request` (`available`, `requested`, `downloading`, `failed`)
    /// action; nil for a stateless one (and on an older server).
    public let state: String?
    /// The label for each state (`Labels`), so a client shows the state's label without knowing the states.
    public let labels: [String: String]
    /// Whether a tap does anything (`Enabled`); an action without the field is enabled.
    public let isEnabled: Bool

    public init(
        id: String,
        label: String,
        icon: String?,
        kind: String,
        state: String? = nil,
        labels: [String: String] = [:],
        enabled: Bool = true
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.kind = kind
        self.state = state
        self.labels = labels
        self.isEnabled = enabled
    }

    /// The same action in another state, with that state's label.
    func with(state newState: String) -> ItemAction {
        ItemAction(
            id: id,
            label: labels[newState] ?? label,
            icon: icon,
            kind: kind,
            state: newState,
            labels: labels,
            enabled: isEnabled
        )
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
        await fetchActions(transport: transport, path: "Items/\(itemID)/Actions")
    }

    /// The items to play, in order, for a `play-queue` action (see `fetchQueue`). With `listID` (a film opened from a list page), the
    /// server starts at the film and continues through that list;
    /// a server that doesn't know the parameter ignores it.
    public func queue(itemID: String, actionID: String, listID: String? = nil) async throws -> [ItemActionQueueEntry] {
        let query = listID.map { ["listId": $0] } ?? [:]
        return try await fetchQueue(transport: transport, path: "Items/\(itemID)/Actions/\(actionID)/Queue", query: query)
    }

    /// Performs a `toggle` or `request` action (`POST Items/{id}/Actions/{actionId}`) and returns the action as it is
    /// now. On a trailer, the server performs it on the trailer's film.
    public func perform(itemID: String, actionID: String) async throws -> ItemAction {
        let response = try await transport.send(method: "POST", path: "Items/\(itemID)/Actions/\(actionID)", query: [:], body: nil)
        guard (200 ..< 300).contains(response.status) else { throw HomeRowsError.status(response.status) }
        guard let action = try itemAction(from: JSONValue.parse(response.body)) else { throw HomeRowsError.invalidResponse }
        return action
    }
}

/// The actions at `path`, in the server's order. Empty on any failure, so a page never shows an error for them.
func fetchActions(transport: HomeRowsTransport, path: String) async -> [ItemAction] {
    guard let response = try? await transport.send(method: "GET", path: path, query: [:], body: nil),
          (200 ..< 300).contains(response.status),
          let entries = (try? JSONValue.parse(response.body))?.array
    else { return [] }

    return entries.compactMap(itemAction(from:))
}

/// One action from the server's JSON, or nil without an `Id` or `Kind`.
func itemAction(from value: JSONValue) -> ItemAction? {
    guard let object = value.object,
          let id = object["Id"]?.string,
          let kind = object["Kind"]?.string
    else { return nil }

    var labels: [String: String] = [:]
    for (state, label) in object["Labels"]?.object?.entries ?? [] {
        if let label = nonEmpty(label.string) {
            labels[state] = label
        }
    }

    return ItemAction(
        id: id,
        label: object["Label"]?.string ?? id,
        icon: object["Icon"]?.string,
        kind: kind,
        state: nonEmpty(object["State"]?.string),
        labels: labels,
        enabled: object["Enabled"]?.bool ?? true
    )
}

/// The queue at `path`. `ItemIds` gives the order; `Items` adds a title, subtitle and film id per id. An older server
/// sends only `ItemIds`; a response with only `Items` uses its order.
func fetchQueue(transport: HomeRowsTransport, path: String, query: [String: String] = [:]) async throws -> [ItemActionQueueEntry] {
    let response = try await transport.send(method: "GET", path: path, query: query, body: nil)
    guard (200 ..< 300).contains(response.status) else { throw HomeRowsError.status(response.status) }
    guard let object = try JSONValue.parse(response.body).object else { throw HomeRowsError.invalidResponse }

    let items: [ItemActionQueueEntry] = (object["Items"]?.array ?? []).compactMap { value in
        guard let entry = value.object, let id = entry["Id"]?.string else { return nil }
        return ItemActionQueueEntry(
            id: id,
            title: nonEmpty(entry["Title"]?.string),
            subtitle: nonEmpty(entry["Subtitle"]?.string),
            filmID: nonEmpty(entry["FilmId"]?.string)
        )
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

func nonEmpty(_ string: String?) -> String? {
    guard let string, !string.isEmpty else { return nil }
    return string
}

/// One item of a server queue, with the title and subtitle the player shows for it when the server names it, and the
/// film it belongs to (`FilmId`: the owned film if there is one, else the discovery copy; nil on an older server).
public struct ItemActionQueueEntry: Equatable, Sendable {

    public let id: String
    public let title: String?
    public let subtitle: String?
    public let filmID: String?

    public init(id: String, title: String?, subtitle: String?, filmID: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.filmID = filmID
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
    /// Save: on or off; a tap flips it.
    public static let toggle = "toggle"
    /// Download: a tap records a request; its state follows the request.
    public static let request = "request"
}

/// The states of a `toggle` action.
public enum ItemActionToggleState {
    public static let on = "on"
    public static let off = "off"
}

public enum ItemActionID {
    public static let watchTrailer = "watch-trailer"
    /// A list page's Watch trailers (the whole list).
    public static let watchTrailers = "watch-trailers"
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
    /// One per `toggle` or `request` action (Save, Download), in the server's order.
    public let stateButtons: [ItemActionStateButton]
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
        showStockTrailers: hasStockTrailers && !hasWatchTrailer,
        stateButtons: actions.compactMap(stateButton(for:))
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

/// The SF Symbol for a server icon name; `isOn` fills it for a toggle that's on. Unknown names are `play.fill`.
public func actionSystemImage(icon: String?, isOn: Bool = false) -> String {
    switch icon {
    case "trailer": "film"
    case "bookmark": isOn ? "bookmark.fill" : "bookmark"
    case "download": "arrow.down.circle"
    default: "play.fill"
    }
}

// MARK: - Toggle and request actions

/// A button for a `toggle` or `request` action, as its current state shows it.
public struct ItemActionStateButton: Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    /// The current state's label (`Labels[State]`), else the action's own label.
    public let label: String
    public let systemImage: String
    /// A toggle that's on (drawn filled and highlighted).
    public let isOn: Bool
    public let isEnabled: Bool
}

/// The button for `action` when it's a `toggle` or `request`; nil for any other kind (play-queue, or a kind this
/// client doesn't know, which it ignores).
public func stateButton(for action: ItemAction) -> ItemActionStateButton? {
    guard action.kind == ItemActionKind.toggle || action.kind == ItemActionKind.request else { return nil }
    let isOn = action.kind == ItemActionKind.toggle && action.state == ItemActionToggleState.on
    return ItemActionStateButton(
        id: action.id,
        kind: action.kind,
        label: action.state.flatMap { action.labels[$0] } ?? action.label,
        systemImage: actionSystemImage(icon: action.icon, isOn: isOn),
        isOn: isOn,
        isEnabled: action.isEnabled
    )
}

/// What a tap shows before the server answers: a toggle flipped to its other state. Nil for a request, which waits
/// for the server.
public func optimisticAction(_ action: ItemAction) -> ItemAction? {
    guard action.kind == ItemActionKind.toggle else { return nil }
    let isOn = action.state == ItemActionToggleState.on
    return action.with(state: isOn ? ItemActionToggleState.off : ItemActionToggleState.on)
}

/// `actions` with the action of the same id replaced by `updated`, in place. Without one, `actions` unchanged.
public func replacingAction(_ updated: ItemAction, in actions: [ItemAction]) -> [ItemAction] {
    actions.map { $0.id == updated.id ? updated : $0 }
}

/// The player's top bar: the `toggle` and `request` buttons (never play-queue actions, nor unknown kinds). Up to
/// `maxInline` show beside Audio & Subtitles; with more, they all go into one overflow menu.
public func playerActionLayout(
    actions: [ItemAction],
    maxInline: Int = 2
) -> (inline: [ItemActionStateButton], overflow: [ItemActionStateButton]) {
    let buttons = actions.compactMap(stateButton(for:))
    return buttons.count > maxInline ? ([], buttons) : (buttons, [])
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
