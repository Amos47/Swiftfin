//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import PlayerCore
import SwiftUI

/// Personal fork: the download quality, in App Settings.
struct DownloadSettingsSection: View {

    @Default(.downloadQuality)
    private var quality

    var body: some View {
        Section {
            Picker(L10n.downloadQuality, selection: $quality)
        } header: {
            Text(L10n.downloads)
        } footer: {
            Text(L10n.downloadQualityFooter)
        }
    }
}
