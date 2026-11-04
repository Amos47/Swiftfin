//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
@testable import HomeRowsCore
import JellyfinAPI
import XCTest

private func item(_ type: BaseItemKind) -> BaseItemDto {
    BaseItemDto(id: UUID().uuidString, type: type)
}

private func presentation(_ shape: String) -> HomeRowPresentation {
    HomeRowPresentation(cardShape: shape, preferredImageType: "Primary")
}

private func row(enabled: Bool = true, available: Bool = true, title: String? = nil, provider: String = "genre") -> HomeRowInstance {
    HomeRowInstance(id: UUID(), provider: provider, title: title, enabled: enabled, isAvailable: available)
}

private func items(_ list: [BaseItemDto] = [item(.episode)], error: String? = nil, title: String? = nil) -> HomeRowItems {
    HomeRowItems(rowID: UUID(), title: title, items: list, presentation: presentation("Thumb"), error: error)
}

private func itemsJSON(_ rowID: String) -> String {
    #"{"RowId":"\#(rowID)","Title":"Row \#(rowID)","Items":[{"Id":"\#(UUID().uuidString)","Type":"Episode"}],"Presentation":{"CardShape":"Thumb","PreferredImageType":"Thumb"}}"#
}

private func configurationJSON(_ rows: [(UUID, Bool)]) -> String {
    let list = rows.map { #"{"Id":"\#($0.0.uuidString)","Provider":"genre","Config":{},"Enabled":\#($0.1)}"# }
    return #"{"ApiVersion":1,"Source":"User","IsCustomized":true,"Rows":[\#(list.joined(separator: ","))]}"#
}

final class HomeRowsDisplayTests: XCTestCase {

    override func setUp() async throws {
        await HomeRowsAPI.clearSupportCache()
    }

    func testButtonShapeIsLibraryButtons() {
        XCTAssertEqual(homeRowStyle(presentation: presentation("Button"), items: [item(.collectionFolder)]), .libraryButtons)
    }

    func testAllLibraryItemsAreLibraryTiles() {
        XCTAssertEqual(homeRowStyle(presentation: presentation("Thumb"), items: [item(.collectionFolder), item(.userView)]), .libraryTiles)
    }

    func testEmptyItemsWithThumbStayLandscape() {
        XCTAssertEqual(homeRowStyle(presentation: presentation("Thumb"), items: []), .landscape)
    }

    func testPosterAndSquareMap() {
        XCTAssertEqual(homeRowStyle(presentation: presentation("Poster"), items: [item(.series)]), .portrait)
        XCTAssertEqual(homeRowStyle(presentation: presentation("Square"), items: [item(.series)]), .square)
    }

    func testUnknownShapeFallsBackToLandscape() {
        XCTAssertEqual(homeRowStyle(presentation: presentation("Hexagon"), items: [item(.movie)]), .landscape)
    }

    func testIsRowShownHidesDisabledUnavailableFailedNeedsConfigurationAndEmptyRows() {
        XCTAssertTrue(isRowShown(row: row(), items: items()))
        XCTAssertFalse(isRowShown(row: row(enabled: false), items: items()))
        XCTAssertFalse(isRowShown(row: row(available: false), items: items()))
        XCTAssertFalse(isRowShown(row: row(), items: nil))
        XCTAssertFalse(isRowShown(row: row(), items: items(error: "needs-configuration")))
        XCTAssertFalse(isRowShown(row: row(), items: items([])))
    }

    func testTitlePrefersCustomTitleThenItemsTitleThenProvider() {
        XCTAssertEqual(homeRowTitle(row: row(title: " Comfort "), items: items(title: "Genre: Comedy"), provider: nil), "Comfort")
        XCTAssertEqual(homeRowTitle(row: row(title: "  "), items: items(title: "Genre: Comedy"), provider: nil), "Genre: Comedy")
        XCTAssertEqual(homeRowTitle(row: row(), items: items(title: nil), provider: HomeRowProvider(id: "genre", name: "Genre")), "Genre")
        XCTAssertEqual(homeRowTitle(row: row(), items: items(title: nil), provider: nil), "genre")
    }

    func testLoadHomeRowsReturnsNilOnAStockServer() async {
        let transport = FakeTransport { _, _ in (404, "") }
        let rows = await loadHomeRows(api: HomeRowsAPI(transport: transport, serverKey: "s"))
        XCTAssertNil(rows)
    }

    func testLoadHomeRowsKeepsOrderAndDropsFailedRows() async throws {
        let ids = [UUID(), UUID(), UUID()]
        let transport = FakeTransport { _, path in
            if path == "HomeRows/Configuration" {
                return (200, configurationJSON(ids.map { ($0, true) }))
            }
            if path == "HomeRows/\(ids[1].uuidString)/Items" {
                return (500, "")
            }
            return (200, itemsJSON(path.split(separator: "/")[1].description))
        }

        let loaded = await loadHomeRows(api: HomeRowsAPI(transport: transport, serverKey: "s"))
        let rows = try XCTUnwrap(loaded)

        XCTAssertEqual(rows.map(\.row.id), [ids[0], ids[2]])
        XCTAssertEqual(rows.first?.title, "Row \(ids[0].uuidString)")
        XCTAssertEqual(rows.first?.style, .landscape)
    }

    func testLoadHomeRowsDropsRowsThatTimeOut() async throws {
        let ids = [UUID(), UUID()]
        let transport = FakeTransport { _, path in
            if path == "HomeRows/Configuration" {
                return (200, configurationJSON(ids.map { ($0, true) }))
            }
            if path == "HomeRows/\(ids[0].uuidString)/Items" {
                try await Task.sleep(for: .seconds(5))
            }
            return (200, itemsJSON(path.split(separator: "/")[1].description))
        }

        let start = Date()
        let loaded = await loadHomeRows(api: HomeRowsAPI(transport: transport, serverKey: "s"), timeout: .milliseconds(200))
        let rows = try XCTUnwrap(loaded)

        XCTAssertEqual(rows.map(\.row.id), [ids[1]])
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "the timed-out request must be cancelled, not awaited")
    }

    func testLoadHomeRowsSkipsDisabledRowsWithoutRequestingItems() async throws {
        let enabled = UUID()
        let disabled = UUID()
        let transport = FakeTransport { _, path in
            if path == "HomeRows/Configuration" {
                return (200, configurationJSON([(enabled, true), (disabled, false)]))
            }
            return (200, itemsJSON(path.split(separator: "/")[1].description))
        }

        let loaded = await loadHomeRows(api: HomeRowsAPI(transport: transport, serverKey: "s"))
        let rows = try XCTUnwrap(loaded)

        XCTAssertEqual(rows.map(\.row.id), [enabled])
        XCTAssertFalse(transport.calls.contains { $0.path == "HomeRows/\(disabled.uuidString)/Items" })
    }
}
