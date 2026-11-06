//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import PlayerCore

// Personal fork: the app-wide download quality setting.

extension DownloadQuality: Defaults.Serializable, Displayable {

    var displayTitle: String {
        switch self {
        case .standard: L10n.downloadQualityStandard
        case .higher: L10n.downloadQualityHigher
        }
    }
}

extension Defaults.Keys {

    static let downloadQuality: Key<DownloadQuality> = Key("downloadQuality", default: .standard, suite: .appSuite)
}
