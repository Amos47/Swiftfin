//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

@testable import PlayerCore
import XCTest

final class CardActionsTests: XCTestCase {

    // MARK: - Tap

    func testWideEpisodeMoviesSeriesPlayAnywhere() {
        for kind in [CardItemKind.episode, .movie, .series] {
            XCTAssertEqual(cardTap(kind: kind, isWide: true), .play)
        }
    }

    func testOtherKindsOpen() {
        XCTAssertEqual(cardTap(kind: .other, isWide: true), .open)
    }

    func testPostersOpen() {
        XCTAssertEqual(cardTap(kind: .episode, isWide: false), .open)
        XCTAssertEqual(cardTap(kind: .series, isWide: false), .open)
    }

    // MARK: - Menu

    func testMenuOnPosterStartsWithPlay() {
        let items = cardMenuItems(kind: .series, tapPlays: false, hasProgress: false, isPlayed: false, isFavourite: false)
        XCTAssertEqual(items.first, .play)
        XCTAssertEqual(items, [.play, .goToItem, .markWatched(true), .favourite(true)])
    }

    func testMenuOnHomeWideHasNoPlay() {
        let items = cardMenuItems(kind: .episode, tapPlays: true, hasProgress: true, isPlayed: false, isFavourite: false)
        XCTAssertEqual(items, [.playFromBeginning, .goToItem, .goToShow, .markWatched(true), .favourite(true)])
    }

    func testPlayFromBeginningOnlyForEpisodeOrMovieWithProgress() {
        XCTAssertTrue(cardMenuItems(kind: .movie, tapPlays: false, hasProgress: true, isPlayed: false, isFavourite: false)
            .contains(.playFromBeginning))
        XCTAssertFalse(cardMenuItems(kind: .movie, tapPlays: false, hasProgress: false, isPlayed: false, isFavourite: false)
            .contains(.playFromBeginning))
        XCTAssertFalse(cardMenuItems(kind: .series, tapPlays: false, hasProgress: true, isPlayed: false, isFavourite: false)
            .contains(.playFromBeginning))
    }

    func testGoToShowOnlyForEpisodes() {
        XCTAssertTrue(cardMenuItems(kind: .episode, tapPlays: false, hasProgress: false, isPlayed: false, isFavourite: false)
            .contains(.goToShow))
        XCTAssertFalse(cardMenuItems(kind: .movie, tapPlays: false, hasProgress: false, isPlayed: false, isFavourite: false)
            .contains(.goToShow))
    }

    func testWatchedAndFavouriteReflectState() {
        let items = cardMenuItems(kind: .movie, tapPlays: false, hasProgress: false, isPlayed: true, isFavourite: true)
        XCTAssertTrue(items.contains(.markWatched(false)))
        XCTAssertTrue(items.contains(.favourite(false)))
    }

    func testOtherKindHasNoPlay() {
        let items = cardMenuItems(
            kind: .other,
            tapPlays: false,
            hasProgress: true,
            isPlayed: false,
            isFavourite: false,
            canMarkWatched: false
        )
        XCTAssertEqual(items, [.goToItem, .favourite(true)])
    }

    func testSeasonsAndCollectionsCanStillBeMarkedWatched() {
        let items = cardMenuItems(
            kind: .other,
            tapPlays: false,
            hasProgress: false,
            isPlayed: false,
            isFavourite: false,
            canMarkWatched: true
        )
        XCTAssertEqual(items, [.goToItem, .markWatched(true), .favourite(true)])
    }

    // MARK: - Action row

    func testSplitFourOrFewerAllVisible() {
        let split = splitActions([1, 2, 3, 4])
        XCTAssertEqual(split.visible, [1, 2, 3, 4])
        XCTAssertEqual(split.overflow, [])
    }

    func testSplitFiveShowsThreeAndOverflowsTwo() {
        let split = splitActions([1, 2, 3, 4, 5])
        XCTAssertEqual(split.visible, [1, 2, 3])
        XCTAssertEqual(split.overflow, [4, 5])
    }

    // MARK: - Current episode

    private let episodes = [
        EpisodeProgress(id: "a", isPlayed: true, progress: 0),
        EpisodeProgress(id: "b", isPlayed: false, progress: 0.4),
        EpisodeProgress(id: "c", isPlayed: false, progress: 0),
    ]

    func testCurrentEpisodePrefersPreferredWhenInList() {
        XCTAssertEqual(currentEpisodeID(in: episodes, preferredID: "c"), "c")
    }

    func testCurrentEpisodeFallsBackToInProgressThenFirstUnplayed() {
        XCTAssertEqual(currentEpisodeID(in: episodes, preferredID: "zzz"), "b")
        let noneInProgress = [EpisodeProgress(id: "a", isPlayed: true, progress: 0), EpisodeProgress(id: "c", isPlayed: false, progress: 0)]
        XCTAssertEqual(currentEpisodeID(in: noneInProgress, preferredID: nil), "c")
    }

    func testCurrentEpisodeAllWatchedIsNil() {
        XCTAssertNil(currentEpisodeID(in: [EpisodeProgress(id: "a", isPlayed: true, progress: 0)], preferredID: nil))
    }
}
