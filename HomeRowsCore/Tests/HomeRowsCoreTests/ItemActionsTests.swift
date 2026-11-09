//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
@testable import HomeRowsCore
import XCTest

private let watchTrailer = #"{"Id":"watch-trailer","Label":"Watch trailer","Icon":"trailer","Kind":"play-queue"}"#

final class ItemActionsAPITests: XCTestCase {

    private func api(_ transport: FakeTransport) -> ItemActionsAPI {
        ItemActionsAPI(transport: transport)
    }

    func testActionsAskTheItemsActionsRoute() async {
        let transport = FakeTransport { _, _ in (200, "[\(watchTrailer)]") }
        let actions = await api(transport).actions(itemID: "abc")

        XCTAssertEqual(transport.calls.map(\.method), ["GET"])
        XCTAssertEqual(transport.calls.map(\.path), ["Items/abc/Actions"])
        XCTAssertEqual(actions, [ItemAction(id: "watch-trailer", label: "Watch trailer", icon: "trailer", kind: "play-queue")])
    }

    func testActions404IsEmpty() async {
        let transport = FakeTransport { _, _ in (404, "") }
        let actions = await api(transport).actions(itemID: "abc")
        XCTAssertEqual(actions, [])
    }

    func testActionsAnyFailureIsEmpty() async {
        let failing = FakeTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let failed = await api(failing).actions(itemID: "abc")
        XCTAssertEqual(failed, [])

        let serverError = FakeTransport { _, _ in (500, "oops") }
        let errored = await api(serverError).actions(itemID: "abc")
        XCTAssertEqual(errored, [])

        let garbage = FakeTransport { _, _ in (200, "<html>") }
        let unparsed = await api(garbage).actions(itemID: "abc")
        XCTAssertEqual(unparsed, [])
    }

    func testActionsSkipEntriesWithoutIdOrKind() async {
        let transport = FakeTransport { _, _ in (
            200,
            #"[{"Label":"No id","Kind":"play-queue"},{"Id":"x","Label":"No kind"},\#(watchTrailer)]"#
        ) }
        let actions = await api(transport).actions(itemID: "abc")
        XCTAssertEqual(actions.map(\.id), ["watch-trailer"])
    }

    func testQueueKeepsServerOrder() async throws {
        let transport = FakeTransport { _, _ in (200, #"{"ItemIds":["c","a","b"]}"#) }
        let ids = try await api(transport).queue(itemID: "abc", actionID: "watch-trailer")

        XCTAssertEqual(transport.calls.map(\.path), ["Items/abc/Actions/watch-trailer/Queue"])
        XCTAssertEqual(ids, ["c", "a", "b"].map { ItemActionQueueEntry(id: $0, title: nil, subtitle: nil) })
    }

    func testQueueCarriesTitlesFromItems() async throws {
        let transport = FakeTransport { _, _ in (
            200,
            #"{"ItemIds":["c","a"],"Items":[{"Id":"c","Title":"Heat","Subtitle":"Trailer · 1995"},{"Id":"a","Title":"Alien"}]}"#
        ) }
        let entries = try await api(transport).queue(itemID: "abc", actionID: "watch-trailer")
        XCTAssertEqual(entries, [
            ItemActionQueueEntry(id: "c", title: "Heat", subtitle: "Trailer · 1995"),
            ItemActionQueueEntry(id: "a", title: "Alien", subtitle: nil),
        ])
    }

    func testQueueOrderIsItemIdsAndTitlesMatchById() async throws {
        // Items in another order, an empty title, and an id with no entry.
        let transport = FakeTransport { _, _ in (
            200,
            #"{"ItemIds":["a","b","c"],"Items":[{"Id":"c","Title":"Cop"},{"Id":"a","Title":"","Subtitle":"Trailer"}]}"#
        ) }
        let entries = try await api(transport).queue(itemID: "abc", actionID: "watch-trailer")
        XCTAssertEqual(entries, [
            ItemActionQueueEntry(id: "a", title: nil, subtitle: "Trailer"),
            ItemActionQueueEntry(id: "b", title: nil, subtitle: nil),
            ItemActionQueueEntry(id: "c", title: "Cop", subtitle: nil),
        ])
    }

    func testQueueWithOnlyItemsUsesTheirOrder() async throws {
        let transport = FakeTransport { _, _ in (200, #"{"Items":[{"Id":"b","Title":"B"},{"Title":"No id"},{"Id":"a"}]}"#) }
        let entries = try await api(transport).queue(itemID: "abc", actionID: "watch-trailer")
        XCTAssertEqual(entries.map(\.id), ["b", "a"])
        XCTAssertEqual(entries.map(\.title), ["B", nil])
    }

    func testQueueWithNeitherFieldIsInvalid() async {
        let transport = FakeTransport { _, _ in (200, #"{}"#) }
        do {
            _ = try await api(transport).queue(itemID: "abc", actionID: "watch-trailer")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? HomeRowsError, .invalidResponse)
        }
    }

    func testQueueThrowsOnAFailedStatus() async {
        let transport = FakeTransport { _, _ in (404, "") }
        do {
            _ = try await api(transport).queue(itemID: "abc", actionID: "watch-trailer")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? HomeRowsError, .status(404))
        }
    }
}

final class ItemActionPlanTests: XCTestCase {

    private let trailer = ItemAction(id: "watch-trailer", label: "Watch trailer", icon: "trailer", kind: "play-queue")

    func testUnknownKindsIgnored() {
        let plan = actionButtons(
            actions: [
                ItemAction(id: "rate", label: "Rate", icon: "star", kind: "open-sheet"),
                trailer,
                ItemAction(id: "extras", label: "Extras", icon: nil, kind: "play-queue"),
            ],
            hasStockTrailers: false
        )
        XCTAssertEqual(plan.buttons.map(\.id), ["watch-trailer", "extras"])
        XCTAssertEqual(plan.buttons.map(\.label), ["Watch trailer", "Extras"])
    }

    func testWatchTrailerHidesStockTrailers() {
        XCTAssertFalse(actionButtons(actions: [trailer], hasStockTrailers: true).showStockTrailers)
    }

    func testStockTrailersStayWithoutWatchTrailer() {
        XCTAssertTrue(actionButtons(actions: [], hasStockTrailers: true).showStockTrailers)
        XCTAssertFalse(actionButtons(actions: [], hasStockTrailers: false).showStockTrailers)

        let other = ItemAction(id: "extras", label: "Extras", icon: nil, kind: "play-queue")
        XCTAssertTrue(actionButtons(actions: [other], hasStockTrailers: true).showStockTrailers)
    }

    func testWatchTrailerOfAnUnknownKindDoesNotHideStockTrailers() {
        let odd = ItemAction(id: "watch-trailer", label: "Watch trailer", icon: "trailer", kind: "open-web")
        let plan = actionButtons(actions: [odd], hasStockTrailers: true)
        XCTAssertTrue(plan.showStockTrailers)
        XCTAssertEqual(plan.buttons, [])
    }

    func testIconMapping() {
        XCTAssertEqual(actionSystemImage(icon: "trailer"), "film")
        XCTAssertEqual(actionSystemImage(icon: "something-new"), "play.fill")
        XCTAssertEqual(actionSystemImage(icon: nil), "play.fill")

        let plan = actionButtons(actions: [trailer], hasStockTrailers: false)
        XCTAssertEqual(plan.buttons.map(\.systemImage), ["film"])
    }
}

final class ListQueueTests: XCTestCase {

    private let ids = ["a", "b", "c"]

    func testStartHasOnlyNext() {
        XCTAssertEqual(listQueueNeighbours(of: "a", in: ids), ListQueueNeighbours(previous: nil, next: 1))
    }

    func testMiddleHasBoth() {
        XCTAssertEqual(listQueueNeighbours(of: "b", in: ids), ListQueueNeighbours(previous: 0, next: 2))
    }

    func testEndHasOnlyPrevious() {
        let end = listQueueNeighbours(of: "c", in: ids)
        XCTAssertEqual(end, ListQueueNeighbours(previous: 1, next: nil))
        XCTAssertFalse(end.hasNext)
        XCTAssertTrue(end.hasPrevious)
    }

    func testSingleItemHasNeither() {
        let single = listQueueNeighbours(of: "a", in: ["a"])
        XCTAssertFalse(single.hasNext)
        XCTAssertFalse(single.hasPrevious)
    }

    func testUnknownOrNoCurrentHasNeither() {
        XCTAssertEqual(listQueueNeighbours(of: "z", in: ids), ListQueueNeighbours(previous: nil, next: nil))
        XCTAssertEqual(listQueueNeighbours(of: nil, in: ids), ListQueueNeighbours(previous: nil, next: nil))
    }

    func testOrderedByIDsKeepsServerOrderAndDropsMissing() {
        let fetched = [("b", 2), ("a", 1), ("x", 9)]
        let ordered = orderedByIDs(fetched, ids: ["c", "a", "b"]) { $0.0 }
        XCTAssertEqual(ordered.map(\.0), ["a", "b"])
    }
}

final class OrderedByIDsDuplicateTests: XCTestCase {

    func testDuplicateIDsAppearOnceAtFirstPosition() {
        let fetched = [("a", 1), ("b", 2)]
        let ordered = orderedByIDs(fetched, ids: ["a", "b", "a"]) { $0.0 }
        XCTAssertEqual(ordered.map(\.0), ["a", "b"])
    }
}

final class PlaySpotTests: XCTestCase {

    private let trailer = ItemAction(id: "watch-trailer", label: "Watch trailer", icon: "trailer", kind: "play-queue")
    private let extras = ItemAction(id: "extras", label: "Extras", icon: nil, kind: "play-queue")

    func test_play_spot_playable_is_play() {
        XCTAssertEqual(playSpot(isPlayable: true, hasWatchTrailer: true), .play)
        XCTAssertEqual(playSpot(isPlayable: true, hasWatchTrailer: false), .play)
    }

    func test_play_spot_virtual_with_trailer_action_is_watch_trailer() {
        XCTAssertEqual(playSpot(isPlayable: false, hasWatchTrailer: true), .watchTrailer)
    }

    func test_play_spot_virtual_without_is_not_in_library() {
        XCTAssertEqual(playSpot(isPlayable: false, hasWatchTrailer: false), .notInLibrary)
    }

    func test_action_row_omits_watch_trailer_when_in_play_spot() {
        let plan = actionButtons(actions: [trailer, extras], hasStockTrailers: true, watchTrailerInPlaySpot: true)
        XCTAssertEqual(plan.buttons.map(\.id), ["extras"])
        // The play spot's Watch trailer still stands in for the stock Trailers button: one trailer entry on the page.
        XCTAssertFalse(plan.showStockTrailers)

        let inRow = actionButtons(actions: [trailer, extras], hasStockTrailers: true)
        XCTAssertEqual(inRow.buttons.map(\.id), ["watch-trailer", "extras"])
    }

    func testPlaySpotActionPlayableIsNil() {
        XCTAssertNil(playSpotAction(isPlayable: true, hasPlaybackProvider: true, actions: [trailer]))
        XCTAssertNil(playSpotAction(isPlayable: true, hasPlaybackProvider: false, actions: [trailer]))
    }

    /// A season with no folder is reported Virtual but is owned: its playback provider makes it playable.
    func testPlaySpotActionNotPlayableButWithProviderIsNil() {
        XCTAssertNil(playSpotAction(isPlayable: false, hasPlaybackProvider: true, actions: [trailer]))
    }

    func testPlaySpotActionVirtualWithWatchTrailerIsTheAction() {
        XCTAssertEqual(
            playSpotAction(isPlayable: false, hasPlaybackProvider: false, actions: [extras, trailer]),
            ItemActionButton(id: "watch-trailer", label: "Watch trailer", systemImage: "film")
        )
    }

    func testPlaySpotActionVirtualWithoutWatchTrailerIsNil() {
        XCTAssertNil(playSpotAction(isPlayable: false, hasPlaybackProvider: false, actions: [extras]))
        XCTAssertNil(playSpotAction(isPlayable: false, hasPlaybackProvider: false, actions: []))
    }

    func testWatchTrailerButtonIsThePlayQueueAction() {
        XCTAssertEqual(
            watchTrailerButton(actions: [extras, trailer]),
            ItemActionButton(id: "watch-trailer", label: "Watch trailer", systemImage: "film")
        )
        XCTAssertNil(watchTrailerButton(actions: [extras]))
        XCTAssertNil(watchTrailerButton(actions: []))

        let odd = ItemAction(id: "watch-trailer", label: "Watch trailer", icon: "trailer", kind: "open-web")
        XCTAssertNil(watchTrailerButton(actions: [odd]))
    }
}

final class QueueItemTitleTests: XCTestCase {

    private let fallback = QueueItemTitle(title: "Dune", subtitle: "Trailer · 2021")

    func testServerTitleWins() {
        let entry = ItemActionQueueEntry(id: "a", title: "Heat", subtitle: "Trailer · 1995")
        XCTAssertEqual(queueItemTitle(entry: entry, fallback: fallback), QueueItemTitle(title: "Heat", subtitle: "Trailer · 1995"))
    }

    func testServerTitleWithoutSubtitleKeepsNoSubtitle() {
        let entry = ItemActionQueueEntry(id: "a", title: "Heat", subtitle: nil)
        XCTAssertEqual(queueItemTitle(entry: entry, fallback: fallback), QueueItemTitle(title: "Heat", subtitle: nil))
    }

    func testOlderServerUsesTheFallback() {
        let entry = ItemActionQueueEntry(id: "a", title: nil, subtitle: nil)
        XCTAssertEqual(queueItemTitle(entry: entry, fallback: fallback), fallback)
        XCTAssertNil(queueItemTitle(entry: entry, fallback: nil))
    }

    func testFallbackOnlyForItemsOfThePageFilm() {
        let entries = [
            ItemActionQueueEntry(id: "own", title: nil, subtitle: nil),
            ItemActionQueueEntry(id: "other", title: nil, subtitle: nil),
            ItemActionQueueEntry(id: "orphan", title: nil, subtitle: nil),
            ItemActionQueueEntry(id: "named", title: "Heat", subtitle: nil),
        ]
        let titles = queueItemTitles(
            entries: entries,
            parentIDs: ["own": "film", "other": "another-film", "named": "another-film"],
            filmID: "film",
            fallback: fallback
        )
        XCTAssertEqual(titles, ["own": fallback, "named": QueueItemTitle(title: "Heat", subtitle: nil)])
    }

    func testNoFallbackWithoutAFilm() {
        let entries = [ItemActionQueueEntry(id: "own", title: nil, subtitle: nil)]
        XCTAssertEqual(queueItemTitles(entries: entries, parentIDs: ["own": "film"], filmID: nil, fallback: fallback), [:])
    }

    func testTrailerFallbackTitle() {
        XCTAssertEqual(
            trailerFallbackTitle(filmTitle: "Dune", year: 2021, trailerLabel: "Trailer"),
            QueueItemTitle(title: "Dune", subtitle: "Trailer · 2021")
        )
        XCTAssertEqual(
            trailerFallbackTitle(filmTitle: "Dune", year: nil, trailerLabel: "Trailer"),
            QueueItemTitle(title: "Dune", subtitle: "Trailer")
        )
        XCTAssertNil(trailerFallbackTitle(filmTitle: nil, year: 2021, trailerLabel: "Trailer"))
        XCTAssertNil(trailerFallbackTitle(filmTitle: "", year: 2021, trailerLabel: "Trailer"))
    }
}
