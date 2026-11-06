//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

/// Personal fork: one downloaded (or downloading) episode or movie, saved next to its files so it plays offline.
struct DownloadRecord: Codable, Identifiable, Equatable {

    enum State: Codable, Equatable {
        case queued
        case downloading(progress: Double)
        /// Only set once Apple reports the asset playable offline.
        case complete
        case failed(message: String)
    }

    /// The item ID.
    let id: String
    let serverID: String
    let userID: String

    /// The full item as it was when downloaded.
    var item: BaseItemDto
    var mediaSource: MediaSourceInfo
    var segments: [MediaSegmentDto]
    /// The `.movpkg` path relative to the home directory, which changes between app installs.
    var assetRelativePath: String?
    var state: State
    var estimatedBytes: Int64
    var downloadedAt: Date

    var localPositionTicks: Int?
    var localPlayed: Bool = false
    /// When this item was last watched offline; cleared once the server has the progress.
    var localPlayedAt: Date?

    var isComplete: Bool {
        state == .complete
    }
}
