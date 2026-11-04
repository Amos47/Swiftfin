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

private let providersJSON = """
{"ApiVersion":1,"Providers":[
 {"Id":"genre","Name":"Genre","Description":"Items in a genre","Schema":{"type":"object","properties":{
   "genre":{"type":"string","title":"Genre","enum":["Comedy","Drama"]},
   "limit":{"type":"integer","minimum":1,"maximum":50},
   "showWatched":{"type":"boolean"}},"required":["genre"]},
  "Defaults":{"limit":20}},
 {"Id":"next-up","Name":"Next Up","Description":"","Schema":{"type":"object","properties":{}},"Defaults":{}}
]}
"""

private func rowJSON(id: UUID = UUID(), provider: String = "genre", config: String = #"{"genre":"Comedy"}"#, extra: String = "") -> String {
    #"{"Id":"\#(id.uuidString)","Provider":"\#(provider)","Title":null,"Config":\#(config),"Enabled":true\#(extra)}"#
}

/// A fake server: GET returns `rows`; a successful PUT stores the sent rows with fresh ids for new ones.
private final class FakeServer: @unchecked Sendable {

    var rows: String
    var putStatus = 200
    var putBody = ""
    var lastPut: Data?

    init(_ rows: String) {
        self.rows = rows
    }

    lazy var transport = FakeTransport { [unowned self] method, path in
        switch (method, path) {
        case (_, "HomeRows/Providers"):
            (200, providersJSON)
        case ("GET", "HomeRows/Configuration"):
            (200, #"{"ApiVersion":1,"Source":"User","IsCustomized":true,"Rows":\#(rows)}"#)
        case ("PUT", _):
            (putStatus, putBody)
        case ("DELETE", _):
            (204, "")
        default:
            (404, "")
        }
    }

    @MainActor
    func editor() -> HomeRowsEditor {
        HomeRowsEditor(api: HomeRowsAPI(transport: StoringTransport(server: self), serverKey: "s"))
    }
}

/// Stores successful PUTs back into the fake server, assigning ids to new rows.
private struct StoringTransport: HomeRowsTransport {

    let server: FakeServer

    func send(method: String, path: String, query: [String: String], body: Data?) async throws -> (status: Int, body: Data) {
        if method == "PUT" {
            server.lastPut = body
            if (200 ..< 300).contains(server.putStatus), path == "HomeRows/Configuration", let body {
                let sent = try JSONValue.parse(body).object?["Rows"]?.array ?? []
                let stored = sent.map { row -> JSONValue in
                    var object = row.object ?? JSONObject()
                    if object["Id"] == .string(emptyRowID.uuidString) {
                        object["Id"] = .string(UUID().uuidString)
                    }
                    return .object(object)
                }
                server.rows = String(decoding: JSONValue.array(stored).serialized(), as: UTF8.self)
            }
        }
        return try await server.transport.send(method: method, path: path, query: query, body: body)
    }
}

@MainActor
final class HomeRowsEditorTests: XCTestCase {

    func testLoadHasNoPendingEdits() async throws {
        let editor = FakeServer("[\(rowJSON()),\(rowJSON(provider: "next-up", config: "{}"))]").editor()

        try await editor.load()

        XCTAssertTrue(editor.loaded)
        XCTAssertEqual(editor.rows.count, 2)
        XCTAssertEqual(editor.providers.count, 2)
        XCTAssertFalse(editor.hasPendingEdits)
    }

    func testMoveToggleRetitleAndSetValueMakeEditsPendingAndMovingBackClearsThem() async throws {
        let editor = FakeServer("[\(rowJSON()),\(rowJSON(provider: "next-up", config: "{}"))]").editor()
        try await editor.load()
        let first = editor.rows[0].key

        editor.move(key: first, by: 1)
        XCTAssertEqual(editor.rows[1].key, first)
        XCTAssertTrue(editor.hasPendingEdits)
        editor.move(key: first, by: -1)
        XCTAssertFalse(editor.hasPendingEdits)

        editor.setEnabled(key: first, false)
        XCTAssertTrue(editor.hasPendingEdits)
        editor.setEnabled(key: first, true)

        editor.setTitle(key: first, "Comfort")
        XCTAssertEqual(editor.rows[0].row.title, "Comfort")
        editor.setTitle(key: first, "  ")
        XCTAssertNil(editor.rows[0].row.title)
        XCTAssertFalse(editor.hasPendingEdits)

        editor.setValue(key: first, setting: "genre", .string("Drama"))
        XCTAssertEqual(editor.rows[0].row.config["genre"], .string("Drama"))
        XCTAssertTrue(editor.hasPendingEdits)
    }

    func testMoveRowFromToMatchesDragSemantics() async throws {
        let editor = FakeServer("[\(rowJSON()),\(rowJSON()),\(rowJSON())]").editor()
        try await editor.load()
        let keys = editor.rows.map(\.key)

        editor.moveRow(from: IndexSet(integer: 0), to: 3)

        XCTAssertEqual(editor.rows.map(\.key), [keys[1], keys[2], keys[0]])
    }

    func testTitlesAreCutTo100Characters() async throws {
        let editor = FakeServer("[\(rowJSON())]").editor()
        try await editor.load()

        editor.setTitle(key: editor.rows[0].key, String(repeating: "a", count: 150))

        XCTAssertEqual(editor.rows[0].row.title, String(repeating: "a", count: 100))
    }

    func testTwoAddedRowsGetDistinctKeys() async throws {
        let editor = FakeServer("[]").editor()
        try await editor.load()

        let a = editor.add(providerID: "genre")
        let b = editor.add(providerID: "genre")

        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(editor.rows.map(\.row.id), [emptyRowID, emptyRowID])
        XCTAssertEqual(editor.rows[0].row.config["limit"], .number(20))
    }

    func testAddReturnsNilAt20Rows() async throws {
        let editor = FakeServer("[" + (0 ..< 20).map { _ in rowJSON() }.joined(separator: ",") + "]").editor()
        try await editor.load()

        XCTAssertNil(editor.add(providerID: "genre"))
        XCTAssertEqual(editor.rows.count, 20)
    }

    func testOpeningDefaultsIsNotAnEdit() async throws {
        let editor = FakeServer("[\(rowJSON(config: #"{"genre":"Comedy"}"#))]").editor()
        try await editor.load()
        let key = editor.rows[0].key

        // A settings screen writing back what it shows: the default limit, and an unset boolean as false.
        editor.setValue(key: key, setting: "limit", .number(20))
        editor.setValue(key: key, setting: "showWatched", .bool(false))

        XCTAssertFalse(editor.hasPendingEdits)
    }

    func testSaveMapsRows3LimitToTheFourthRowsKey() async throws {
        let server = FakeServer("[\(rowJSON()),\(rowJSON())]")
        let editor = server.editor()
        try await editor.load()
        _ = editor.add(providerID: "genre")
        let fourth = try XCTUnwrap(editor.add(providerID: "genre"))
        server.putStatus = 400
        server.putBody = #"{"errors":{"rows[3].Limit":["Too big"],"Rows":["Too many"]}}"#

        let saved = await editor.save()

        XCTAssertFalse(saved)
        XCTAssertEqual(editor.errors[fourth], ["limit": "Too big"])
        XCTAssertEqual(editor.errors[generalErrorsKey], ["Rows": "Too many"])
    }

    func testSaveKeepsEditsOn400() async throws {
        let server = FakeServer("[\(rowJSON())]")
        let editor = server.editor()
        try await editor.load()
        _ = editor.add(providerID: "next-up")
        server.putStatus = 400
        server.putBody = #"{"errors":{}}"#

        let saved = await editor.save()

        XCTAssertFalse(saved)
        XCTAssertEqual(editor.rows.count, 2)
        XCTAssertTrue(editor.hasPendingEdits)
    }

    func testSaveOn500SetsGeneralErrorAndKeepsEdits() async throws {
        let server = FakeServer("[\(rowJSON())]")
        let editor = server.editor()
        try await editor.load()
        _ = editor.add(providerID: "next-up")
        server.putStatus = 500

        let saved = await editor.save()

        XCTAssertFalse(saved)
        XCTAssertNotNil(editor.generalError)
        XCTAssertEqual(editor.rows.count, 2)
    }

    func testSaveSuccessReloadsAndClearsPending() async throws {
        let editor = FakeServer("[\(rowJSON())]").editor()
        try await editor.load()
        _ = editor.add(providerID: "next-up")

        let saved = await editor.save()

        XCTAssertTrue(saved)
        XCTAssertFalse(editor.hasPendingEdits)
        XCTAssertEqual(editor.rows.count, 2)
        XCTAssertNotEqual(editor.rows[1].row.id, emptyRowID)
    }

    func testDiscardRestoresTheSavedRows() async throws {
        let editor = FakeServer("[\(rowJSON())]").editor()
        try await editor.load()
        _ = editor.add(providerID: "next-up")
        editor.remove(key: editor.rows[0].key)

        editor.discard()

        XCTAssertEqual(editor.rows.map(\.row.provider), ["genre"])
        XCTAssertFalse(editor.hasPendingEdits)
    }

    func testUnavailableRowRoundTripsThroughSaveUnchanged() async throws {
        let gone = UUID()
        let server = FakeServer("[\(rowJSON(id: gone, provider: "removed", config: #"{"x":1}"#, extra: #","IsAvailable":false"#))]")
        let editor = server.editor()
        try await editor.load()
        _ = editor.add(providerID: "next-up")

        let saved = await editor.save()

        XCTAssertTrue(saved)
        let sent = try XCTUnwrap(JSONValue.parse(XCTUnwrap(server.lastPut)).object?["Rows"]?.array?.first?.object)
        XCTAssertEqual(sent["Id"], .string(gone.uuidString))
        XCTAssertEqual(sent["Provider"], .string("removed"))
        XCTAssertEqual(sent["Config"], json(#"{"x":1}"#))
    }

    func testSaveAsDefaultLeavesPendingStateAsItWas() async throws {
        let editor = FakeServer("[\(rowJSON())]").editor()
        try await editor.load()
        _ = editor.add(providerID: "next-up")

        let saved = await editor.saveAsDefault()

        XCTAssertTrue(saved)
        XCTAssertTrue(editor.hasPendingEdits)
    }

    func testResetReloadsTheInheritedLayoutAndDropsEdits() async throws {
        let server = FakeServer("[\(rowJSON())]")
        let editor = server.editor()
        try await editor.load()
        _ = editor.add(providerID: "next-up")
        server.rows = "[]"

        let reset = await editor.reset()

        XCTAssertTrue(reset)
        XCTAssertTrue(editor.rows.isEmpty)
        XCTAssertFalse(editor.hasPendingEdits)
    }

    func testSaveLeavesOnlyWhenTheSaveSucceeds() async throws {
        let server = FakeServer("[\(rowJSON())]")
        let editor = server.editor()
        try await editor.load()
        _ = editor.add(providerID: "next-up")

        server.putStatus = 400
        server.putBody = #"{"errors":{}}"#
        let failed = await editor.resolveLeave(.save)
        XCTAssertFalse(failed)
        XCTAssertTrue(editor.hasPendingEdits)

        server.putStatus = 200
        let saved = await editor.resolveLeave(.save)
        XCTAssertTrue(saved)
        XCTAssertFalse(editor.hasPendingEdits)
    }

    func testDiscardLeavesAndDropsEditsAndKeepEditingStays() async throws {
        let editor = FakeServer("[\(rowJSON())]").editor()
        try await editor.load()
        _ = editor.add(providerID: "next-up")

        let kept = await editor.resolveLeave(.keepEditing)
        XCTAssertFalse(kept)
        XCTAssertTrue(editor.hasPendingEdits)

        let discarded = await editor.resolveLeave(.discard)
        XCTAssertTrue(discarded)
        XCTAssertFalse(editor.hasPendingEdits)
    }
}
