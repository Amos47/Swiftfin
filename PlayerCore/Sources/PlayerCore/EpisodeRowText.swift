//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// The "Last played" date on a watched episode row, in the phone's short date format, so a rewatch can be found on
/// the series page.
public func lastPlayedDateText(
    isPlayed: Bool,
    lastPlayed: Date?,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String? {
    guard isPlayed, let lastPlayed else { return nil }

    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter.string(from: lastPlayed)
}
