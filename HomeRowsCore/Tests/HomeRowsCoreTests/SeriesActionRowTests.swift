//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

@testable import HomeRowsCore
import XCTest

final class SeriesActionRowTests: XCTestCase {

    private let trailer = ItemAction(id: "watch-trailer", label: "Watch trailer", icon: "trailer", kind: "play-queue")
    private let save = ItemAction(
        id: "save",
        label: "Save",
        icon: "bookmark",
        kind: "toggle",
        state: "off",
        labels: ["on": "Saved", "off": "Save"],
        enabled: true
    )
    private let download = ItemAction(
        id: "download",
        label: "Download",
        icon: "download",
        kind: "request",
        state: "available",
        labels: ["available": "Download", "requested": "Requested"],
        enabled: true
    )

    private func row(
        isMissing: Bool = false,
        hasStockTrailers: Bool = false,
        canEdit: Bool = false,
        serverActions: [ItemAction]? = [],
        watchTrailerInPlaySpot: Bool = false
    ) -> [SeriesRowAction] {
        seriesActionRow(
            isMissing: isMissing,
            canBePlayed: true,
            canBeFavorited: true,
            hasStockTrailers: hasStockTrailers,
            canEdit: canEdit,
            serverActions: serverActions,
            watchTrailerInPlaySpot: watchTrailerInPlaySpot
        )
    }

    // MARK: play spot

    /// A virtual series isn't playable and (its playback resolve is `try?`) has no provider, so Watch trailer takes the
    /// Play spot, as for a virtual film.
    func test_play_spot_for_virtual_series_is_watch_trailer() {
        let action = playSpotAction(isPlayable: false, hasPlaybackProvider: false, actions: [save, trailer, download])
        XCTAssertEqual(action, ItemActionButton(id: "watch-trailer", label: "Watch trailer", systemImage: "film"))
        XCTAssertEqual(playSpot(isPlayable: false, hasWatchTrailer: action != nil), .watchTrailer)
    }

    // MARK: server actions

    func test_series_action_row_includes_server_actions() {
        let actions = row(canEdit: true, serverActions: [trailer, save, download])
        XCTAssertEqual(actions.map(\.id), ["watched", "favourite", "server:watch-trailer", "state:save", "state:download", "edit"])
    }

    func test_series_action_row_leaves_watch_trailer_to_the_play_spot() {
        let actions = row(isMissing: true, serverActions: [trailer, save, download], watchTrailerInPlaySpot: true)
        XCTAssertEqual(actions.map(\.id), ["state:save", "state:download"])
    }

    func test_series_state_buttons_carry_the_state_label() {
        let saved = save.with(state: "on")
        guard case let .state(button) = row(serverActions: [saved]).last else { return XCTFail("no Save") }
        XCTAssertEqual(button.label, "Saved")
        XCTAssertTrue(button.isOn)
    }

    /// The stock Trailers button waits for the server's answer (Watch trailer replaces it), as on the film page.
    func test_series_stock_trailers_wait_for_the_server_and_give_way_to_watch_trailer() {
        XCTAssertFalse(row(hasStockTrailers: true, serverActions: nil).contains(.trailers))
        XCTAssertTrue(row(hasStockTrailers: true, serverActions: []).contains(.trailers))
        XCTAssertFalse(row(hasStockTrailers: true, serverActions: [trailer]).contains(.trailers))
    }

    /// A stock server (no actions) keeps today's row.
    func test_series_action_row_without_server_actions_is_unchanged() {
        let actions = row(hasStockTrailers: true, canEdit: true, serverActions: [])
        XCTAssertEqual(actions, [.watched, .favourite, .trailers, .edit])
    }

    // MARK: missing

    func test_missing_series_hides_watched_favorite() {
        let actions = row(isMissing: true, canEdit: true, serverActions: [save])
        XCTAssertFalse(actions.contains(.watched))
        XCTAssertFalse(actions.contains(.favourite))
        XCTAssertEqual(actions.map(\.id), ["state:save", "edit"])
    }
}
