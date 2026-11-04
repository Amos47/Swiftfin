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

func json(_ text: String) -> JSONValue {
    try! JSONValue.parse(Data(text.utf8))
}

let latestProvider = HomeRowProvider(
    id: "latest-media",
    name: "Recently Added",
    description: "The latest items added to a library.",
    schema: json("""
    {"type":"object","properties":{
    "showWatched":{"type":"boolean","title":"Show watched"},
    "limit":{"type":"integer","title":"Limit","minimum":1,"maximum":50},
    "note":{"type":"string","title":"Note","maxLength":200},
    "library":{"type":"string","title":"Library","enum":["a1","b2"],"x-enumLabels":["Shows","Recordings"]},
    "kinds":{"type":"array","title":"Kinds","items":{"type":"string","enum":["Movie","Series"]},"x-enumLabels":["Movies"],"minItems":1},
    "cardStyle":{"type":"string","title":"Card style","enum":["poster","thumb"],"x-enumLabels":["Poster","Thumb"]}
    },"required":["library"]}
    """).object!,
    defaults: json(#"{"showWatched":false,"limit":20,"kinds":["Movie"],"cardStyle":"poster"}"#).object!.dictionary
)

let validConfig: [String: JSONValue] = json(
    #"{"showWatched":true,"limit":10,"note":"hi","library":"a1","kinds":["Series"],"cardStyle":"thumb"}"#
).object!.dictionary

private func with(_ key: String, _ value: JSONValue?) -> [String: JSONValue] {
    var config = validConfig
    config[key] = value
    return config
}

final class HomeRowsSchemaTests: XCTestCase {

    let fields = latestProvider.fields()

    func testFieldsKeepSchemaOrderWithKinds() {
        XCTAssertEqual(fields.map(\.key), ["showWatched", "limit", "note", "library", "kinds", "cardStyle"])
        XCTAssertEqual(fields.map(\.kind), [.boolean, .integer, .string, .enumeration, .multiEnumeration, .enumeration])
    }

    func testFieldsTakeLabelsBoundsRequiredAndDefaults() {
        let showWatched = fields[0], limit = fields[1], note = fields[2], library = fields[3], kinds = fields[4]

        XCTAssertEqual(showWatched.label, "Show watched")
        XCTAssertFalse(showWatched.required)
        XCTAssertEqual(showWatched.defaultValue, .bool(false))
        XCTAssertEqual(limit.min, 1)
        XCTAssertEqual(limit.max, 50)
        XCTAssertEqual(limit.defaultValue, .number(20))
        XCTAssertEqual(note.maxLength, 200)
        XCTAssertTrue(library.required)
        XCTAssertEqual(library.options, [HomeRowOption(value: "a1", label: "Shows"), HomeRowOption(value: "b2", label: "Recordings")])
        XCTAssertEqual(kinds.minItems, 1)
        XCTAssertEqual(kinds.options, [HomeRowOption(value: "Movie", label: "Movies"), HomeRowOption(value: "Series", label: "Series")])
    }

    func testUnknownTypesAreStringsAndUnknownHintsAreIgnored() throws {
        var odd = latestProvider
        odd.schema = try XCTUnwrap(json(#"{"type":"object","properties":{"x":{"type":"number","x-ui":"slider"}}}"#).object)
        odd.defaults = [:]

        let field = odd.fields().first
        XCTAssertEqual(field?.key, "x")
        XCTAssertEqual(field?.kind, .string)
        XCTAssertEqual(field?.label, "x")
    }

    func testEffectiveValueUsesConfigElseDefault() {
        XCTAssertEqual(fields[1].effectiveValue(in: ["limit": .number(5)]), .number(5))
        XCTAssertEqual(fields[1].effectiveValue(in: [:]), .number(20))
        XCTAssertEqual(fields[1].effectiveValue(in: ["limit": .null]), .number(20))
    }

    func testValidConfigHasNoErrors() {
        XCTAssertEqual(validateRowConfig(fields, validConfig), [:])
    }

    func testRequiredSettingsWithoutDefaultAreRequired() {
        XCTAssertEqual(validateRowConfig(fields, with("library", nil)), ["library": .required])
    }

    func testIntegersOutOfRangeOrWithFractions() {
        XCTAssertEqual(validateRowConfig(fields, with("limit", .number(0))), ["limit": .outOfRange])
        XCTAssertEqual(validateRowConfig(fields, with("limit", .number(51))), ["limit": .outOfRange])
        XCTAssertEqual(validateRowConfig(fields, with("limit", .number(2.5))), ["limit": .outOfRange])
    }

    func testIntegerGivenAStringIsOutOfRange() {
        XCTAssertEqual(validateRowConfig(fields, with("limit", .string("ten"))), ["limit": .outOfRange])
    }

    func testStringsOverMaxLengthAreTooLong() {
        XCTAssertEqual(validateRowConfig(fields, with("note", .string(String(repeating: "a", count: 201)))), ["note": .tooLong])
    }

    func testMultiEnumBelowMinItemsNeedsOne() {
        XCTAssertEqual(validateRowConfig(fields, with("kinds", .array([]))), ["kinds": .pickAtLeastOne])
    }

    func testOptionsTheServerNoLongerOffersAreUnknown() {
        XCTAssertEqual(validateRowConfig(fields, with("library", .string("gone"))), ["library": .unknownOption])
        XCTAssertEqual(validateRowConfig(fields, with("kinds", .array([.string("Gone")]))), ["kinds": .unknownOption])
    }

    func testAProviderWithoutPropertiesHasNoFields() {
        var empty = latestProvider
        empty.schema = JSONObject()
        XCTAssertTrue(empty.fields().isEmpty)
    }

    // MARK: - Labels

    private let row = HomeRowInstance(
        id: UUID(),
        provider: "latest-media",
        config: ["library": .string("a1"), "cardStyle": .string("thumb")]
    )

    func testLabelPrefersATrimmedCustomTitle() {
        var titled = row
        titled.title = "  Kids  "
        XCTAssertEqual(editorRowLabel(row: titled, provider: latestProvider), "Kids")
    }

    func testLabelIsProviderNameAndRequiredChoices() {
        XCTAssertEqual(editorRowLabel(row: row, provider: latestProvider), "Recently Added · Shows")

        var recordings = row
        recordings.config = ["library": .string("b2")]
        XCTAssertEqual(editorRowLabel(row: recordings, provider: latestProvider), "Recently Added · Recordings")
    }

    func testLabelIsJustTheProviderNameWhenNothingRequiredIsChosen() {
        var empty = row
        empty.config = [:]
        XCTAssertEqual(editorRowLabel(row: empty, provider: latestProvider), "Recently Added")
    }

    func testLabelForAMissingProviderIsTheProviderID() {
        XCTAssertEqual(editorRowLabel(row: row, provider: nil), "latest-media")
    }
}
