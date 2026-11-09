//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// Personal fork: Custom Home Rows.

extension Notifications.Key {

    /// Posted after the user's home rows layout or the household default changes, so the home screen reloads.
    static var homeRowsDidChange: Key<Void> {
        Key("homeRowsDidChange")
    }

    /// Posted after a Save or Download succeeds (film page or player). Home rebuilds its whole layout the next time it
    /// appears (not behind the player), so a row that was empty, such as Saved, shows up.
    static var homeRowsNeedRebuild: Key<Void> {
        Key("homeRowsNeedRebuild")
    }
}
