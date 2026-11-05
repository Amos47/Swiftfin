//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

// Personal fork: set by Home rows, where tapping a wide card plays it (iPhone). Off everywhere else, and on tvOS.

extension EnvironmentValues {

    @Entry
    var homeCardTapPlays: Bool = false
}
