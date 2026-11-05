//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

// Personal fork: on iPhone, tapping a wide card plays it, everywhere (Home, libraries, search, item pages). Off on tvOS.

extension EnvironmentValues {

    @Entry
    var wideCardTapPlays: Bool = {
        #if os(iOS)
        true
        #else
        false
        #endif
    }()

    /// Whether tapping the card this menu belongs to already plays it, so the menu leaves out Play.
    @Entry
    var cardTapPlays: Bool = false
}
