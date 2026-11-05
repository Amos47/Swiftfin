//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

// Personal fork: scroll actions for the item page, provided by `ItemView` on iPhone.

extension EnvironmentValues {

    /// Scrolls the item page back to its header.
    @Entry
    var scrollItemPageToTop: (() -> Void)? = nil

    /// Scrolls the item page to the view with this id (e.g. an episode row).
    @Entry
    var scrollItemPage: ((AnyHashable, UnitPoint) -> Void)? = nil
}
