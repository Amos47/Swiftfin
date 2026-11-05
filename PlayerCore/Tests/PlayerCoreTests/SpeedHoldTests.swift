//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

@testable import PlayerCore
import XCTest

final class SpeedHoldTests: XCTestCase {

    func testHoldAppliesHoldRateAndReleaseRestores() {
        var hold = SpeedHold(holdRate: 2)

        XCTAssertEqual(hold.pressBegan(currentRate: 1), 2)
        XCTAssertEqual(hold.state, .holding)
        XCTAssertEqual(hold.pressEnded(), 1)
        XCTAssertEqual(hold.state, .idle)
    }

    func testDragPastThresholdLocks() {
        var hold = SpeedHold(holdRate: 2)
        _ = hold.pressBegan(currentRate: 1)

        hold.dragged(downBy: 61)

        XCTAssertEqual(hold.state, .locked)
        XCTAssertNil(hold.pressEnded())
        XCTAssertEqual(hold.state, .locked)
    }

    func testDragUnderThresholdDoesNotLock() {
        var hold = SpeedHold(holdRate: 2)
        _ = hold.pressBegan(currentRate: 1)

        hold.dragged(downBy: 40)

        XCTAssertEqual(hold.state, .holding)
        XCTAssertEqual(hold.pressEnded(), 1)
    }

    func testDraggingUpDoesNotLock() {
        var hold = SpeedHold(holdRate: 2)
        _ = hold.pressBegan(currentRate: 1)

        hold.dragged(downBy: -80)

        XCTAssertEqual(hold.state, .holding)
    }

    func testTapPillUnlocksToOriginalRate() {
        var hold = SpeedHold(holdRate: 2)
        _ = hold.pressBegan(currentRate: 1.25)
        hold.dragged(downBy: 70)
        _ = hold.pressEnded()

        XCTAssertEqual(hold.tapPill(), 1.25)
        XCTAssertEqual(hold.state, .idle)
    }

    func testTapPillWhenNotLockedDoesNothing() {
        var hold = SpeedHold(holdRate: 2)

        XCTAssertNil(hold.tapPill())
    }

    func testPressWhileLockedUnlocksToOriginalRate() {
        var hold = SpeedHold(holdRate: 2)
        _ = hold.pressBegan(currentRate: 1)
        hold.dragged(downBy: 70)
        _ = hold.pressEnded()

        XCTAssertEqual(hold.pressBegan(currentRate: 2), 1)
        XCTAssertEqual(hold.state, .unlocking)
        hold.dragged(downBy: 90)
        XCTAssertEqual(hold.state, .unlocking)
        XCTAssertNil(hold.pressEnded())
        XCTAssertEqual(hold.state, .idle)
    }

    func testCustomLockDistance() {
        var hold = SpeedHold(holdRate: 3, lockDistance: 100)
        XCTAssertEqual(hold.pressBegan(currentRate: 1), 3)

        hold.dragged(downBy: 80)
        XCTAssertEqual(hold.state, .holding)
        hold.dragged(downBy: 101)
        XCTAssertEqual(hold.state, .locked)
    }
}
