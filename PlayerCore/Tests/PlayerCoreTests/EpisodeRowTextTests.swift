//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
@testable import PlayerCore
import XCTest

final class EpisodeRowTextTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let date = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!

    func testPlayedWithDate_USLocale() {
        XCTAssertEqual(
            lastPlayedDateText(isPlayed: true, lastPlayed: date, locale: Locale(identifier: "en_US"), timeZone: utc),
            "11/6/26"
        )
    }

    func testPlayedWithDate_UKLocale() {
        XCTAssertEqual(
            lastPlayedDateText(isPlayed: true, lastPlayed: date, locale: Locale(identifier: "en_GB"), timeZone: utc),
            "06/11/2026"
        )
    }

    func testUnplayed_Nil() {
        XCTAssertNil(lastPlayedDateText(isPlayed: false, lastPlayed: date, locale: Locale(identifier: "en_US"), timeZone: utc))
    }

    func testNoDate_Nil() {
        XCTAssertNil(lastPlayedDateText(isPlayed: true, lastPlayed: nil, locale: Locale(identifier: "en_US"), timeZone: utc))
    }
}
