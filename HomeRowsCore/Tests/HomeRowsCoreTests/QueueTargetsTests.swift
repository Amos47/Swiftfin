//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

@testable import HomeRowsCore
import XCTest

final class QueueTargetsTests: XCTestCase {

    /// As the episode queue sees an episode: no media sources fetched.
    private func ok(_ id: String) -> QueueCandidate {
        QueueCandidate(id: id, isMissing: false, isUnaired: false, hasMedia: nil)
    }

    private func missing(_ id: String) -> QueueCandidate {
        QueueCandidate(id: id, isMissing: true, isUnaired: false, hasMedia: nil)
    }

    // MARK: rule

    func testValidTarget() {
        XCTAssertTrue(isValidQueueTarget(ok("a")))
        // Media sources not fetched: not known, so not ruled out.
        XCTAssertTrue(isValidQueueTarget(QueueCandidate(id: "a", isMissing: false, isUnaired: false, hasMedia: nil)))
    }

    func testMissingOrMedialessIsNotATarget() {
        XCTAssertFalse(isValidQueueTarget(missing("a")))
        XCTAssertFalse(isValidQueueTarget(QueueCandidate(id: "a", isMissing: false, isUnaired: false, hasMedia: false)))
    }

    func testUnairedIsSkippedOnlyWhenAlsoVirtual() {
        // A real file with a future premiere date plays.
        XCTAssertTrue(isValidQueueTarget(QueueCandidate(id: "a", isMissing: false, isUnaired: true, hasMedia: nil)))
        XCTAssertFalse(isValidQueueTarget(QueueCandidate(id: "a", isMissing: true, isUnaired: true, hasMedia: nil)))
    }

    // MARK: neighbours

    func testMissingMiddleEpisodeIsSkipped() {
        let episodes = [ok("e1"), missing("e2"), ok("e3")]

        let fromFirst = playableNeighbours(of: "e1", in: episodes)
        XCTAssertNil(fromFirst.previous)
        XCTAssertEqual(fromFirst.next, 2)

        let fromLast = playableNeighbours(of: "e3", in: episodes)
        XCTAssertEqual(fromLast.previous, 0)
        XCTAssertNil(fromLast.next)
    }

    func testMissingLastEpisodeGivesNoNext() {
        let episodes = [ok("e1"), ok("e2"), missing("e3")]
        let neighbours = playableNeighbours(of: "e2", in: episodes)
        XCTAssertEqual(neighbours.previous, 0)
        XCTAssertNil(neighbours.next)
        XCTAssertFalse(neighbours.hasNext)
    }

    func testSeveralInvalidInARowAreSkipped() {
        let unaired = QueueCandidate(id: "e4", isMissing: true, isUnaired: true, hasMedia: nil)
        let empty = QueueCandidate(id: "e3", isMissing: false, isUnaired: false, hasMedia: false)
        let episodes = [missing("e0"), ok("e1"), missing("e2"), empty, unaired, ok("e5")]
        let neighbours = playableNeighbours(of: "e1", in: episodes)
        XCTAssertNil(neighbours.previous)
        XCTAssertEqual(neighbours.next, 5)
    }

    func testUnknownCurrentHasNoNeighbours() {
        let neighbours = playableNeighbours(of: "x", in: [ok("a"), ok("b")])
        XCTAssertNil(neighbours.previous)
        XCTAssertNil(neighbours.next)
        XCTAssertNil(playableNeighbours(of: nil, in: [ok("a")]).next)
    }

    // MARK: fixed list

    func testDeletedTrailerIdIsDropped() {
        // "b" was deleted: the items fetch didn't return it.
        let fetched = [ok("c"), ok("a")]
        XCTAssertEqual(playableQueue(ids: ["a", "b", "c"], fetched: fetched, candidate: { $0 }).map(\.id), ["a", "c"])
    }

    func testUnplayableTrailerIsDroppedAndDuplicatesKeptOnce() {
        let empty = QueueCandidate(id: "b", isMissing: false, isUnaired: false, hasMedia: false)
        let fetched = [ok("a"), empty, ok("c")]
        XCTAssertEqual(playableQueue(ids: ["a", "b", "c", "a"], fetched: fetched, candidate: { $0 }).map(\.id), ["a", "c"])
    }

    func testNothingPlayableIsEmpty() {
        XCTAssertEqual(playableQueue(ids: ["a"], fetched: [missing("a")], candidate: { $0 }), [])
        XCTAssertEqual(playableQueue(ids: ["a"], fetched: [QueueCandidate](), candidate: { $0 }), [])
    }
}
