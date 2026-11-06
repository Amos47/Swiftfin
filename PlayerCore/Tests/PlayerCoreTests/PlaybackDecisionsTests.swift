//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

@testable import PlayerCore
import XCTest

final class PlaybackDecisionsTests: XCTestCase {

    private let hls = StreamShape.hls(subtitleRenditions: [2, 3], audioRenditions: [1])

    // MARK: - Subtitles

    func testSubtitleOffNeverRebuilds() {
        XCTAssertEqual(subtitleSwitch(to: -1, isTextSubtitle: true, shape: hls), .deselectSubtitles)
        XCTAssertEqual(subtitleSwitch(to: -1, isTextSubtitle: true, shape: .staticFile), .deselectSubtitles)
    }

    func testTurningOffBurnedInSubtitlesRebuilds() {
        XCTAssertEqual(
            subtitleSwitch(to: -1, isTextSubtitle: true, shape: hls, fromBurnedIn: true),
            .rebuild(disableDirectPlay: false)
        )
    }

    func testTextSubtitleInManifestSelectsInStream() {
        XCTAssertEqual(subtitleSwitch(to: 3, isTextSubtitle: true, shape: hls), .selectInStream(index: 3))
    }

    func testTextSubtitleNotInManifestRebuilds() {
        XCTAssertEqual(subtitleSwitch(to: 4, isTextSubtitle: true, shape: hls), .rebuild(disableDirectPlay: false))
    }

    func testStaticFileTextSubtitleRebuildsAsRemux() {
        XCTAssertEqual(subtitleSwitch(to: 2, isTextSubtitle: true, shape: .staticFile), .rebuild(disableDirectPlay: true))
    }

    func testImageSubtitleAlwaysRebuilds() {
        XCTAssertEqual(subtitleSwitch(to: 2, isTextSubtitle: false, shape: hls), .rebuild(disableDirectPlay: false))
        XCTAssertEqual(subtitleSwitch(to: 2, isTextSubtitle: false, shape: .staticFile), .rebuild(disableDirectPlay: false))
    }

    // MARK: - Audio

    func testAudioInManifestSelectsInStream() {
        XCTAssertEqual(audioSwitch(to: 1, shape: hls), .selectInStream(index: 1))
    }

    func testAudioNotInManifestRebuilds() {
        XCTAssertEqual(audioSwitch(to: 5, shape: hls), .rebuild(disableDirectPlay: false))
    }

    func testAudioOnStaticRebuilds() {
        XCTAssertEqual(audioSwitch(to: 1, shape: .staticFile), .rebuild(disableDirectPlay: false))
    }

    // MARK: - Fallback

    private func fallback(
        failed: Bool = false,
        waited: Double = 0,
        buffering: Bool = false,
        hadFrame: Bool = false,
        retried: Bool = false,
        pip: Bool = false
    ) -> FallbackDecision {
        fallbackDecision(
            failed: failed,
            secondsWithoutFirstFrame: waited,
            isBuffering: buffering,
            hadFirstFrame: hadFrame,
            alreadyRetried: retried,
            isPictureInPictureActive: pip
        )
    }

    func testHealthyPlaybackNeedsNothing() {
        XCTAssertEqual(fallback(waited: 3), .none)
        XCTAssertEqual(fallback(hadFrame: true), .none)
    }

    func testFailedBeforeFirstFrameSwitchesToVLC() {
        XCTAssertEqual(fallback(failed: true, waited: 2), .switchToVLC)
    }

    func testNoFrameAfter15sNotBufferingSwitches() {
        XCTAssertEqual(fallback(waited: 15), .switchToVLC)
        XCTAssertEqual(fallback(waited: 14.9), .none)
    }

    func testStillBufferingAt15sWaits() {
        XCTAssertEqual(fallback(waited: 20, buffering: true), .none)
    }

    func testMidPlaybackFailureRetriesOnceThenOffers() {
        XCTAssertEqual(fallback(failed: true, hadFrame: true), .retryApple)
        XCTAssertEqual(fallback(failed: true, hadFrame: true, retried: true), .offerVLC)
    }

    func testRetryThatFailsBeforeFirstFrameOffersVLC() {
        XCTAssertEqual(fallback(failed: true, retried: true), .offerVLC)
        XCTAssertEqual(fallback(waited: 15, retried: true), .offerVLC)
    }

    func testNoSwitchDuringPiP() {
        XCTAssertEqual(fallback(failed: true, hadFrame: true, pip: true), .retryApple)
        XCTAssertEqual(fallback(failed: true, hadFrame: true, retried: true, pip: true), .offerVLC)
        XCTAssertEqual(fallback(failed: true, pip: true), .retryApple)
    }

    // MARK: - Downloads

    func testDownloadsNeverGoToVLC() {
        XCTAssertEqual(downloadFallbackDecision(.switchToVLC), .showError)
        XCTAssertEqual(downloadFallbackDecision(.offerVLC), .showError)
        XCTAssertEqual(downloadFallbackDecision(.retryApple), .retryApple)
        XCTAssertEqual(downloadFallbackDecision(.none), .none)
    }

    // MARK: - Reported position

    func testBriefPlayBeforeTheSavedSpotKeepsTheSavedSpot() {
        // Opened at 0:00 though 7:00 was saved, closed after 4 seconds.
        XCTAssertEqual(reportedPosition(current: 4, saved: 420, furthestReached: 4, secondsPlayed: 4), 420)
    }

    func testResumingAndWatchingReportsTheRealPosition() {
        XCTAssertEqual(reportedPosition(current: 430, saved: 420, furthestReached: 430, secondsPlayed: 10), 430)
    }

    func testRewindingAfterReachingTheSavedSpotIsKept() {
        XCTAssertEqual(reportedPosition(current: 60, saved: 420, furthestReached: 425, secondsPlayed: 8), 60)
    }

    func testLongerViewingIsAlwaysReported() {
        XCTAssertEqual(reportedPosition(current: 200, saved: 420, furthestReached: 200, secondsPlayed: 200), 200)
    }

    func testNothingSavedReportsTheRealPosition() {
        XCTAssertEqual(reportedPosition(current: 4, saved: nil, furthestReached: 4, secondsPlayed: 4), 4)
        XCTAssertEqual(reportedPosition(current: 4, saved: 0, furthestReached: 4, secondsPlayed: 4), 4)
    }
}
