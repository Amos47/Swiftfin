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

private let watchTrailers = #"{"Id":"watch-trailers","Label":"Watch trailers","Icon":"trailer","Kind":"play-queue"}"#

final class DiscoveryListAPITests: XCTestCase {

    private func api(_ transport: FakeTransport) -> DiscoveryListAPI {
        DiscoveryListAPI(transport: transport)
    }

    // MARK: Page

    func testPageAsksTheListPageRouteAndDecodes() async throws {
        let transport = FakeTransport { _, _ in (
            200,
            #"""
            {"Id":"crime-90s","Title":"90s crime","Overview":"Heists and cops.","BackdropItemId":"b1","PrimaryItemId":"p1",
             "Items":[{"Id":"f1","Name":"Heat","Type":"Movie","PremiereDate":"1995-12-15T00:00:00.0000000Z"},
                      {"Id":"f2","Name":"Se7en","Type":"Movie"}]}
            """#
        ) }
        let page = try await api(transport).page(listID: "crime-90s")

        XCTAssertEqual(transport.calls.map(\.method), ["GET"])
        XCTAssertEqual(transport.calls.map(\.path), ["Discovery/Lists/crime-90s/Page"])
        XCTAssertEqual(page.id, "crime-90s")
        XCTAssertEqual(page.title, "90s crime")
        XCTAssertEqual(page.overview, "Heists and cops.")
        XCTAssertEqual(page.backdropItemID, "b1")
        XCTAssertEqual(page.primaryItemID, "p1")
        XCTAssertEqual(page.items.map(\.id), ["f1", "f2"])
        XCTAssertEqual(page.items.map(\.name), ["Heat", "Se7en"])
        XCTAssertNotNil(page.items.first?.premiereDate)
    }

    func testPageOptionalFieldsMayBeMissing() async throws {
        let transport = FakeTransport { _, _ in (200, #"{"Id":"x","Title":"X","Items":[]}"#) }
        let page = try await api(transport).page(listID: "x")

        XCTAssertNil(page.overview)
        XCTAssertNil(page.backdropItemID)
        XCTAssertNil(page.primaryItemID)
        XCTAssertEqual(page.items, [])
    }

    func testPageEmptyOverviewIsNil() async throws {
        let transport = FakeTransport { _, _ in (200, #"{"Id":"x","Title":"X","Overview":"","Items":[]}"#) }
        let page = try await api(transport).page(listID: "x")
        XCTAssertNil(page.overview)
    }

    func testPageWithoutItemsHasNone() async throws {
        let transport = FakeTransport { _, _ in (200, #"{"Id":"x","Title":"X"}"#) }
        let page = try await api(transport).page(listID: "x")
        XCTAssertEqual(page.items, [])
    }

    func testPageUnknownListThrows404() async {
        let transport = FakeTransport { _, _ in (404, "") }
        do {
            _ = try await api(transport).page(listID: "gone")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? HomeRowsError, .status(404))
        }
    }

    // MARK: Actions

    func testActionsAskTheListActionsRoute() async {
        let transport = FakeTransport { _, _ in (200, "[\(watchTrailers)]") }
        let actions = await api(transport).actions(listID: "crime-90s")

        XCTAssertEqual(transport.calls.map(\.path), ["Discovery/Lists/crime-90s/Actions"])
        XCTAssertEqual(actions, [ItemAction(id: "watch-trailers", label: "Watch trailers", icon: "trailer", kind: "play-queue")])
    }

    func testActionsFailureIsEmpty() async {
        let notFound = await api(FakeTransport { _, _ in (404, "") }).actions(listID: "x")
        XCTAssertEqual(notFound, [])

        let offline = await api(FakeTransport { _, _ in throw URLError(.notConnectedToInternet) }).actions(listID: "x")
        XCTAssertEqual(offline, [])

        let garbage = await api(FakeTransport { _, _ in (200, "<html>") }).actions(listID: "x")
        XCTAssertEqual(garbage, [])
    }

    func testActionsSkipEntriesWithoutIdOrKind() async {
        let transport = FakeTransport { _, _ in (200, #"[{"Label":"No id","Kind":"play-queue"},{"Id":"y"},\#(watchTrailers)]"#) }
        let actions = await api(transport).actions(listID: "x")
        XCTAssertEqual(actions.map(\.id), ["watch-trailers"])
    }

    // MARK: Queue

    func testQueueAsksTheListQueueRouteWithFilmIDs() async throws {
        let transport = FakeTransport { _, _ in (
            200,
            #"{"ItemIds":["t1","t2"],"Items":[{"Id":"t1","Title":"Heat","Subtitle":"Trailer · 1995","FilmId":"f1"},{"Id":"t2","Title":"Se7en","FilmId":"f2"}]}"#
        ) }
        let entries = try await api(transport).queue(listID: "crime-90s", actionID: "watch-trailers")

        XCTAssertEqual(transport.calls.map(\.path), ["Discovery/Lists/crime-90s/Actions/watch-trailers/Queue"])
        XCTAssertEqual(entries, [
            ItemActionQueueEntry(id: "t1", title: "Heat", subtitle: "Trailer · 1995", filmID: "f1"),
            ItemActionQueueEntry(id: "t2", title: "Se7en", subtitle: nil, filmID: "f2"),
        ])
    }

    func testQueueThrowsOnAFailedStatus() async {
        let transport = FakeTransport { _, _ in (404, "") }
        do {
            _ = try await api(transport).queue(listID: "x", actionID: "watch-trailers")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? HomeRowsError, .status(404))
        }
    }
}

final class ItemActionsQueueContextTests: XCTestCase {

    func testFilmQueueWithListIDPassesIt() async throws {
        let transport = FakeTransport { _, _ in (200, #"{"ItemIds":["t1"]}"#) }
        _ = try await ItemActionsAPI(transport: transport).queue(itemID: "f1", actionID: "watch-trailer", listID: "crime-90s")

        XCTAssertEqual(transport.calls.map(\.path), ["Items/f1/Actions/watch-trailer/Queue"])
        XCTAssertEqual(transport.calls.map(\.query), [["listId": "crime-90s"]])
    }

    func testFilmQueueWithoutListIDSendsNoQuery() async throws {
        let transport = FakeTransport { _, _ in (200, #"{"ItemIds":["t1"]}"#) }
        _ = try await ItemActionsAPI(transport: transport).queue(itemID: "f1", actionID: "watch-trailer")
        XCTAssertEqual(transport.calls.map(\.query), [[:]])
    }

    func testQueueEntriesCarryFilmIDWhenTheServerSendsIt() async throws {
        let transport = FakeTransport { _, _ in (
            200,
            #"{"ItemIds":["t1","t2","t3"],"Items":[{"Id":"t1","FilmId":"f1"},{"Id":"t2","FilmId":""},{"Id":"t3"}]}"#
        ) }
        let entries = try await ItemActionsAPI(transport: transport).queue(itemID: "f1", actionID: "watch-trailer")
        XCTAssertEqual(entries.map(\.filmID), ["f1", nil, nil])
    }
}

final class CloseTargetTests: XCTestCase {

    private func entry(_ filmID: String?) -> ItemActionQueueEntry {
        ItemActionQueueEntry(id: "t", title: nil, subtitle: nil, filmID: filmID)
    }

    func testAnotherFilmIsTheTarget() {
        XCTAssertEqual(closeTarget(startFilmID: "f1", currentEntry: entry("f2")), "f2")
    }

    func testTheSameFilmIsNoTarget() {
        XCTAssertNil(closeTarget(startFilmID: "f1", currentEntry: entry("f1")))
    }

    func testAMissingFilmIDIsNoTarget() {
        XCTAssertNil(closeTarget(startFilmID: "f1", currentEntry: entry(nil)))
        XCTAssertNil(closeTarget(startFilmID: nil, currentEntry: entry(nil)))
    }

    func testNoEntryIsNoTarget() {
        XCTAssertNil(closeTarget(startFilmID: "f1", currentEntry: nil))
    }

    func testAQueueStartedFromAListTargetsTheCurrentFilm() {
        XCTAssertEqual(closeTarget(startFilmID: nil, currentEntry: entry("f1")), "f1")
    }
}

final class ListPagePlanTests: XCTestCase {

    private let trailers = ItemAction(id: "watch-trailers", label: "Watch trailers", icon: "trailer", kind: "play-queue")

    func testFirstPlayQueueActionTakesThePlaySpot() {
        let plan = listPageActions(actions: [
            ItemAction(id: "rate", label: "Rate", icon: nil, kind: "open-sheet"),
            trailers,
            ItemAction(id: "extras", label: "Extras", icon: nil, kind: "play-queue"),
        ])
        XCTAssertEqual(plan.primary?.id, "watch-trailers")
        XCTAssertEqual(plan.primary?.label, "Watch trailers")
        XCTAssertEqual(plan.primary?.systemImage, "film")
        XCTAssertEqual(plan.row.map(\.id), ["extras"])
    }

    func testNoActionsIsAnEmptyPlan() {
        let plan = listPageActions(actions: [ItemAction(id: "rate", label: "Rate", icon: nil, kind: "open-sheet")])
        XCTAssertNil(plan.primary)
        XCTAssertEqual(plan.row, [])
    }
}

final class PageListPresentationTests: XCTestCase {

    func testPresentationDecodesPageListID() throws {
        let json = #"{"CardShape":"Thumb","PageListId":"crime-90s"}"#
        let presentation = try JSONDecoder().decode(HomeRowPresentation.self, from: Data(json.utf8))
        XCTAssertEqual(presentation.pageListID, "crime-90s")
    }

    func testOlderServerHasNoPageListID() throws {
        let json = #"{"CardShape":"Thumb"}"#
        let presentation = try JSONDecoder().decode(HomeRowPresentation.self, from: Data(json.utf8))
        XCTAssertNil(presentation.pageListID)
    }

    func testEmptyPageListIDIsNone() throws {
        let json = #"{"CardShape":"Thumb","PageListId":""}"#
        let presentation = try JSONDecoder().decode(HomeRowPresentation.self, from: Data(json.utf8))
        XCTAssertNil(presentation.pageListID)
    }
}

final class CloseNavigationTests: XCTestCase {

    func testAFilmNotInThePathIsPushed() {
        XCTAssertEqual(closeNavigation(targetID: "item-f2", pathIDs: ["discovery-list-x", "item-f1"]), .push)
        XCTAssertEqual(closeNavigation(targetID: "item-f2", pathIDs: []), .push)
    }

    func testAFilmOnTopStays() {
        XCTAssertEqual(closeNavigation(targetID: "item-f1", pathIDs: ["discovery-list-x", "item-f1"]), .stay)
    }

    func testAFilmDeeperInThePathIsPoppedBackTo() {
        XCTAssertEqual(
            closeNavigation(targetID: "item-f1", pathIDs: ["item-f1", "discovery-list-x", "item-f2"]),
            .popTo(index: 0)
        )
    }

    func testTheNearestCopyIsPoppedBackTo() {
        XCTAssertEqual(
            closeNavigation(targetID: "item-f1", pathIDs: ["item-f1", "x", "item-f1", "item-f3"]),
            .popTo(index: 2)
        )
    }
}

final class FocusFreshnessTests: XCTestCase {

    func testARecentRequestIsFresh() {
        let posted = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(isFocusRequestFresh(postedAt: posted, now: posted.addingTimeInterval(5)))
    }

    func testAnOldRequestIsStale() {
        let posted = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(isFocusRequestFresh(postedAt: posted, now: posted.addingTimeInterval(31)))
    }
}
