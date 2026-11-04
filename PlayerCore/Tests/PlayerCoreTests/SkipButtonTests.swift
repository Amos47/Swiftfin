//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

@testable import PlayerCore
import XCTest

final class SkipButtonTests: XCTestCase {

    private let intro = SkipSegment(kind: .intro, start: 60, end: 100)
    private let outro = SkipSegment(kind: .outro, start: 1250, end: 1300)

    private func button(
        _ position: Double,
        runtime: Double? = 1300,
        segments: [SkipSegment],
        hasNext: Bool = false,
        isLive: Bool = false,
        entered: Double? = nil
    ) -> SkipButton? {
        skipButton(
            position: position,
            runtime: runtime,
            segments: segments,
            hasNextItem: hasNext,
            isLive: isLive,
            enteredSegmentAt: entered
        )
    }

    func testInsideIntroShowsSkipIntroToEnd() {
        XCTAssertEqual(button(70, segments: [intro], entered: 70), .skip(.intro, to: 100, prominent: true))
    }

    func testResumedMidIntroStillShows() {
        XCTAssertEqual(button(95, segments: [intro], entered: 95), .skip(.intro, to: 100, prominent: true))
    }

    func testJustEnteredWithoutEntryTimeIsProminent() {
        XCTAssertEqual(button(95, segments: [intro]), .skip(.intro, to: 100, prominent: true))
    }

    func testProminenceEndsAfter8Seconds() {
        XCTAssertEqual(button(79, segments: [intro], entered: 70), .skip(.intro, to: 100, prominent: false))
    }

    func testOutsideSegmentsNoButton() {
        XCTAssertNil(button(120, segments: [intro]))
    }

    func testSegmentEndIsExclusive() {
        XCTAssertNil(button(100, segments: [intro], entered: 60))
    }

    func testOutroWithNextBecomesNextEpisode() {
        XCTAssertEqual(button(1260, segments: [outro], hasNext: true, entered: 1260), .nextEpisode(prominent: true))
    }

    func testOutroWithoutNextIsSkipCredits() {
        XCTAssertEqual(button(1260, segments: [outro], entered: 1260), .skip(.outro, to: 1300, prominent: true))
    }

    func testLast30sWithoutOutroShowsNextEpisode() {
        XCTAssertEqual(button(1275, segments: [], hasNext: true), .nextEpisode(prominent: true))
    }

    func testLast30sWithoutNextShowsNothing() {
        XCTAssertNil(button(1275, segments: []))
    }

    func testBeforeLast30sNoNextEpisode() {
        XCTAssertNil(button(1260, segments: [], hasNext: true))
    }

    func testLiveNeverShows() {
        XCTAssertNil(button(70, segments: [intro], isLive: true, entered: 70))
    }

    func testPreviewShowsSkipPreview() {
        let preview = SkipSegment(kind: .preview, start: 1200, end: 1240)
        XCTAssertEqual(button(1210, segments: [preview], entered: 1210), .skip(.preview, to: 1240, prominent: true))
    }

    func testRecapShowsSkipRecap() {
        let recap = SkipSegment(kind: .recap, start: 0, end: 45)
        XCTAssertEqual(button(3, segments: [recap], entered: 3), .skip(.recap, to: 45, prominent: true))
    }

    func testOverlappingSegmentsPreferLatestStart() {
        let recap = SkipSegment(kind: .recap, start: 0, end: 80)
        XCTAssertEqual(button(70, segments: [recap, intro], entered: 70), .skip(.intro, to: 100, prominent: true))
    }
}
