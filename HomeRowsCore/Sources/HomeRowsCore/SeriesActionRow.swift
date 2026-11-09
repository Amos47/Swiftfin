//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

// Personal fork: the iPhone series page's action row, with the server's actions (Save, Download, Watch trailer).

/// One button in the series page's action row.
public enum SeriesRowAction: Equatable, Sendable, Identifiable {
    case watched
    case favourite
    /// A server `play-queue` action (Watch trailer when it isn't in the Play spot).
    case server(ItemActionButton)
    /// A server `toggle` or `request` action (Save, Download).
    case state(ItemActionStateButton)
    /// The stock Trailers menu (local and external trailers).
    case trailers
    case edit

    public var id: String {
        switch self {
        case .watched: "watched"
        case .favourite: "favourite"
        case let .server(button): "server:\(button.id)"
        case let .state(button): "state:\(button.id)"
        case .trailers: "trailers"
        case .edit: "edit"
        }
    }
}

/// The series page's action row, in order: Watched, Favourite, the server's play-queue actions, its Save and Download,
/// Trailers, Edit. The server's part comes from `actionButtons`, the film page's rule.
///
/// - Parameters:
///   - isMissing: a virtual series (discovery, not in the library) has nothing to mark watched or favourite.
///   - hasStockTrailers: whether the stock Trailers menu would show (local or external trailers, per the setting).
///   - serverActions: the server's actions, or nil while its answer is still coming; the stock Trailers menu waits for
///     it, so Watch trailer replaces it instead of swapping in.
///   - watchTrailerInPlaySpot: Watch trailer is in the Play spot, so the row leaves it out.
public func seriesActionRow(
    isMissing: Bool,
    canBePlayed: Bool,
    canBeFavorited: Bool,
    hasStockTrailers: Bool,
    canEdit: Bool,
    serverActions: [ItemAction]?,
    watchTrailerInPlaySpot: Bool
) -> [SeriesRowAction] {
    let plan = actionButtons(
        actions: serverActions ?? [],
        hasStockTrailers: hasStockTrailers,
        watchTrailerInPlaySpot: watchTrailerInPlaySpot
    )

    var actions: [SeriesRowAction] = []
    if canBePlayed, !isMissing {
        actions.append(.watched)
    }
    if canBeFavorited, !isMissing {
        actions.append(.favourite)
    }
    actions += plan.buttons.map(SeriesRowAction.server)
    actions += plan.stateButtons.map(SeriesRowAction.state)
    if serverActions != nil, plan.showStockTrailers {
        actions.append(.trailers)
    }
    if canEdit {
        actions.append(.edit)
    }
    return actions
}
