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

final class DownloadRulesTests: XCTestCase {

    // MARK: - Stream request

    func testSmallHEVCSourceIsCopied() {
        let request = downloadStreamRequest(
            sourceVideoCodec: "hevc",
            sourceVideoBitrate: 1_184_764,
            firstTextSubtitleIndex: nil,
            quality: .standard
        )
        XCTAssertTrue(request.copiesVideo)
        XCTAssertEqual(request.videoBitrate, 40_000_000)
    }

    func testLargeSourceIsTranscoded() {
        let request = downloadStreamRequest(
            sourceVideoCodec: "hevc",
            sourceVideoBitrate: 3_612_669,
            firstTextSubtitleIndex: nil,
            quality: .standard
        )
        XCTAssertFalse(request.copiesVideo)
        XCTAssertEqual(request.videoBitrate, 2_000_000)
        XCTAssertEqual(request.audioBitrate, 128_000)
    }

    func testHigherQualityCopiesUpToFiveMegabits() {
        let request = downloadStreamRequest(
            sourceVideoCodec: "H264",
            sourceVideoBitrate: 4_500_000,
            firstTextSubtitleIndex: nil,
            quality: .higher
        )
        XCTAssertTrue(request.copiesVideo)
        XCTAssertEqual(request.audioBitrate, 192_000)
    }

    func testUnknownCodecOrBitrateTranscodes() {
        XCTAssertFalse(
            downloadStreamRequest(
                sourceVideoCodec: "mpeg2video",
                sourceVideoBitrate: 1_000_000,
                firstTextSubtitleIndex: nil,
                quality: .standard
            ).copiesVideo
        )
        XCTAssertFalse(
            downloadStreamRequest(
                sourceVideoCodec: "hevc",
                sourceVideoBitrate: nil,
                firstTextSubtitleIndex: nil,
                quality: .standard
            ).copiesVideo
        )
    }

    func testSubtitleIndexPassedThrough() {
        XCTAssertEqual(
            downloadStreamRequest(sourceVideoCodec: "hevc", sourceVideoBitrate: 1, firstTextSubtitleIndex: 2, quality: .standard)
                .subtitleStreamIndex,
            2
        )
        XCTAssertNil(
            downloadStreamRequest(sourceVideoCodec: "hevc", sourceVideoBitrate: 1, firstTextSubtitleIndex: nil, quality: .standard)
                .subtitleStreamIndex
        )
    }

    // MARK: - Size estimate

    func testEstimateForTranscode() {
        let request = downloadStreamRequest(
            sourceVideoCodec: "hevc",
            sourceVideoBitrate: 9_000_000,
            firstTextSubtitleIndex: nil,
            quality: .standard
        )
        XCTAssertEqual(
            estimatedDownloadBytes(request, sourceBitrate: 9_000_000, runtimeSeconds: 3600),
            Int64((2_000_000 + 128_000) * 3600 / 8)
        )
    }

    func testEstimateForCopyUsesSourceBitrate() {
        let request = downloadStreamRequest(
            sourceVideoCodec: "hevc",
            sourceVideoBitrate: 1_184_764,
            firstTextSubtitleIndex: nil,
            quality: .standard
        )
        let estimate = estimatedDownloadBytes(request, sourceBitrate: 1_184_764, runtimeSeconds: 1316.6)
        XCTAssertEqual(Double(estimate), 1_184_764 * 1316.6 / 8, accuracy: 1)
    }

    // MARK: - Next downloaded episode

    func testNextDownloadedEpisodeSkipsGapsAndSeasons() {
        let episodes = [
            DownloadedEpisode(id: "s2e1", season: 2, episode: 1),
            DownloadedEpisode(id: "s1e3", season: 1, episode: 3),
            DownloadedEpisode(id: "s1e1", season: 1, episode: 1),
        ]
        XCTAssertEqual(nextDownloadedEpisode(after: "s1e1", in: episodes), "s1e3")
        XCTAssertEqual(nextDownloadedEpisode(after: "s1e3", in: episodes), "s2e1")
        XCTAssertNil(nextDownloadedEpisode(after: "s2e1", in: episodes))
        XCTAssertNil(nextDownloadedEpisode(after: "unknown", in: episodes))
    }

    // MARK: - End action

    func testEndActionNextAndDelete() {
        XCTAssertEqual(
            downloadEndAction(isDownloaded: true, atNextEpisodeMoment: true, nextDownloadedID: "next"),
            .nextAndDelete(nextID: "next")
        )
    }

    func testEndActionDeleteWhenNoNext() {
        XCTAssertEqual(downloadEndAction(isDownloaded: true, atNextEpisodeMoment: true, nextDownloadedID: nil), .delete)
    }

    func testEndActionNilWhenNotDownloaded() {
        XCTAssertNil(downloadEndAction(isDownloaded: false, atNextEpisodeMoment: true, nextDownloadedID: "next"))
    }

    func testEndActionNilBeforeTheMoment() {
        XCTAssertNil(downloadEndAction(isDownloaded: true, atNextEpisodeMoment: false, nextDownloadedID: "next"))
    }

    // MARK: - Progress sync

    func testProgressSync() {
        let downloaded = Date(timeIntervalSince1970: 1000)
        let server = Date(timeIntervalSince1970: 2000)

        XCTAssertEqual(progressSyncDecision(localPlayedAt: nil, downloadedAt: downloaded, serverLastPlayed: server), .keepServer)
        XCTAssertEqual(
            progressSyncDecision(localPlayedAt: Date(timeIntervalSince1970: 3000), downloadedAt: downloaded, serverLastPlayed: server),
            .sendLocal
        )
        XCTAssertEqual(
            progressSyncDecision(localPlayedAt: Date(timeIntervalSince1970: 1500), downloadedAt: downloaded, serverLastPlayed: nil),
            .sendLocal
        )
        XCTAssertEqual(
            progressSyncDecision(localPlayedAt: Date(timeIntervalSince1970: 1500), downloadedAt: downloaded, serverLastPlayed: server),
            .keepServer
        )
        XCTAssertEqual(
            progressSyncDecision(localPlayedAt: Date(timeIntervalSince1970: 500), downloadedAt: downloaded, serverLastPlayed: nil),
            .keepServer
        )
    }
}
