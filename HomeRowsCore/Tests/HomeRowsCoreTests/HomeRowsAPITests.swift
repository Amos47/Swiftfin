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

/// Records requests and answers them from a closure.
final class FakeTransport: HomeRowsTransport, @unchecked Sendable {

    struct Call {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    let respond: @Sendable (String, String) async throws -> (Int, String)

    init(_ respond: @escaping @Sendable (String, String) async throws -> (Int, String)) {
        self.respond = respond
    }

    var calls: [Call] {
        lock.withLock { _calls }
    }

    func send(method: String, path: String, query: [String: String], body: Data?) async throws -> (status: Int, body: Data) {
        lock.withLock { _calls.append(Call(method: method, path: path, query: query, body: body)) }
        let (status, text) = try await respond(method, path)
        return (status, Data(text.utf8))
    }
}

let configurationV1 = #"{"ApiVersion":1,"Source":"User","IsCustomized":true,"Rows":[]}"#

final class HomeRowsAPITests: XCTestCase {

    override func setUp() async throws {
        await HomeRowsAPI.clearSupportCache()
    }

    private func api(_ transport: FakeTransport, server: String = "http://a") -> HomeRowsAPI {
        HomeRowsAPI(transport: transport, serverKey: server)
    }

    func testIsSupportedTrueForApiVersion1() async {
        let transport = FakeTransport { _, _ in (200, configurationV1) }
        let supported = await api(transport).isSupported()
        XCTAssertTrue(supported)
    }

    func testIsSupportedFalseForApiVersion2() async {
        let transport = FakeTransport { _, _ in (200, #"{"ApiVersion":2,"Source":"User","IsCustomized":true,"Rows":[]}"#) }
        let supported = await api(transport).isSupported()
        XCTAssertFalse(supported)
    }

    func testIsSupportedCachesA404PerServer() async {
        let transport = FakeTransport { _, _ in (404, "") }

        let first = await api(transport).isSupported()
        let second = await api(transport).isSupported()
        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertEqual(transport.calls.count, 1)

        _ = await api(transport, server: "http://b").isSupported()
        XCTAssertEqual(transport.calls.count, 2)
    }

    func testIsSupportedDoesNotCacheA500() async {
        let transport = FakeTransport { _, _ in (500, "") }

        _ = await api(transport).isSupported()
        _ = await api(transport).isSupported()
        XCTAssertEqual(transport.calls.count, 2)
    }

    func testItemsDecodesBaseItemDtoAndPresentation() async throws {
        let rowID = UUID()
        let itemID = UUID()
        let transport = FakeTransport { _, _ in
            (200, """
            {"RowId":"\(rowID)","Title":"Next Up","Items":[{"Id":"\(itemID.uuidString)","Name":"Pilot","Type":"Episode",
            "PremiereDate":"2026-10-01T00:00:00.0000000Z"}],
            "TotalRecordCount":1,"StartIndex":0,"Presentation":{"CardShape":"Thumb","PreferredImageType":"Thumb"},"Error":null}
            """)
        }

        let items = try await api(transport).items(rowID: rowID)

        XCTAssertEqual(items.items.first?.name, "Pilot")
        XCTAssertEqual(items.items.first?.type, .episode)
        XCTAssertNotNil(items.items.first?.premiereDate)
        XCTAssertEqual(items.presentation.cardShape, "Thumb")
        XCTAssertEqual(items.title, "Next Up")
        XCTAssertEqual(transport.calls.first?.path, "HomeRows/\(rowID.uuidString)/Items")
        XCTAssertEqual(transport.calls.first?.query["limit"], "20")
    }

    func testSaveSendsPutWithRowsAndKeepsUnknownConfigKeys() async throws {
        let transport = FakeTransport { _, _ in (200, configurationV1) }
        let config: [String: JSONValue] = [
            "genre": .string("Comedy"),
            "somethingNew": .object(JSONObject([("nested", .number(3))])),
        ]
        let row = HomeRowInstance(id: emptyRowID, provider: "genre", title: nil, config: config, enabled: true)

        let result = try await api(transport).saveConfiguration([row])

        XCTAssertEqual(result, .saved)
        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(call.method, "PUT")
        XCTAssertEqual(call.path, "HomeRows/Configuration")
        let sent = try sentRow(call)
        XCTAssertEqual(sent["Config"], .object(JSONObject(config.map { ($0.key, $0.value) })))
        XCTAssertEqual(sent["Provider"], .string("genre"))
    }

    func testSaveSendsEnabledAndTitleEvenWhenDefaults() async throws {
        let transport = FakeTransport { _, _ in (200, configurationV1) }
        let row = HomeRowInstance(id: emptyRowID, provider: "genre", title: nil, config: [:], enabled: true)

        _ = try await api(transport).saveConfiguration([row])

        let sent = try sentRow(XCTUnwrap(transport.calls.first))
        XCTAssertEqual(sent["Enabled"], .bool(true))
        XCTAssertEqual(sent["Title"], .null)
        XCTAssertTrue(sent.keys.contains("Title"))
    }

    func testSaveMaps400Errors() async throws {
        let transport = FakeTransport { _, _ in
            (400, #"{"title":"One or more validation errors occurred.","errors":{"rows[2].limit":["Too big"]}}"#)
        }

        let result = try await api(transport).saveConfiguration([])

        XCTAssertEqual(result, .invalid(["rows[2].limit": ["Too big"]]))
    }

    func testRevisionBumpsOnlyOnSuccess() async throws {
        let status = Box(400)
        let transport = FakeTransport { _, _ in (status.value, #"{"errors":{}}"#) }
        let api = api(transport)

        _ = try await api.saveConfiguration([])
        var revision = await api.revision
        XCTAssertEqual(revision, 0)

        status.value = 204
        try await api.resetConfiguration()
        revision = await api.revision
        XCTAssertEqual(revision, 1)
    }

    func testConfigurationThrowsStatusOn500() async {
        let transport = FakeTransport { _, _ in (500, "") }

        do {
            _ = try await api(transport).configuration()
            XCTFail("Expected an error")
        } catch let HomeRowsError.status(status) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testJSONValueRoundTripsNestedObjectsAndNumbers() throws {
        let text = #"{"b":[1,2.5,true,null,"x"],"a":{"z":-3,"y":{"k":"v"}},"n":1e3}"#
        let value = try JSONValue.parse(Data(text.utf8))
        let again = try JSONValue.parse(value.serialized())

        XCTAssertEqual(value, again)
        XCTAssertEqual(value.object?.keys, ["b", "a", "n"])
        XCTAssertEqual(value.object?["n"], .number(1000))
        XCTAssertEqual(String(decoding: JSONValue.number(20).serialized(), as: UTF8.self), "20")
    }

    private func sentRow(_ call: FakeTransport.Call) throws -> JSONObject {
        let body = try JSONValue.parse(XCTUnwrap(call.body))
        let rows = try XCTUnwrap(body.object?["Rows"]?.array)
        return try XCTUnwrap(rows.first?.object)
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) {
        self.value = value
    }
}

final class JellyfinDateTests: XCTestCase {

    func testParsesSevenFractionalDigitsAndMissingZone() throws {
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T12:34:56Z")).addingTimeInterval(0.123)

        XCTAssertEqual(
            try XCTUnwrap(parseJellyfinDate("2026-10-01T12:34:56.1234567Z")).timeIntervalSince1970,
            expected.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(parseJellyfinDate("2026-10-01T12:34:56.123")).timeIntervalSince1970,
            expected.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertNotNil(parseJellyfinDate("2026-10-01T12:34:56+02:00"))
        XCTAssertNil(parseJellyfinDate("not a date"))
    }
}

/// The server writes GUIDs in .NET "N" format (32 hex digits, no dashes).
final class ServerGUIDFormatTests: XCTestCase {

    override func setUp() async throws {
        await HomeRowsAPI.clearSupportCache()
    }

    func testConfigurationAndItemsAcceptNFormatIDs() async throws {
        let transport = FakeTransport { _, path in
            if path == "HomeRows/Configuration" {
                return (
                    200,
                    #"{"ApiVersion":1,"Source":"User","IsCustomized":true,"Rows":[{"Id":"b66b8900e8106b0855bd08f909db4c7d","Provider":"library-buttons","Config":{},"Enabled":true,"IsAvailable":true}]}"#
                )
            }
            return (
                200,
                #"{"RowId":"b66b8900e8106b0855bd08f909db4c7d","Items":[],"Presentation":{"CardShape":"Button","PreferredImageType":"Primary"}}"#
            )
        }
        let api = HomeRowsAPI(transport: transport, serverKey: "n")

        let supported = await api.isSupported()
        XCTAssertTrue(supported)
        let configuration = try await api.configuration()
        XCTAssertEqual(configuration.rows.first?.id, UUID(uuidString: "B66B8900-E810-6B08-55BD-08F909DB4C7D"))
        let items = try await api.items(rowID: XCTUnwrap(configuration.rows.first?.id))
        XCTAssertEqual(items.rowID, configuration.rows.first?.id)
    }
}
