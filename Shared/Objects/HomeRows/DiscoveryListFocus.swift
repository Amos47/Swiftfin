//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation
import HomeRowsCore
import SwiftUI

// Personal fork: discovery list pages.

/// The film a list page should scroll to: closing the player on a trailer queue from that list names the film that was
/// playing, and the list page underneath (if any) scrolls to it.
@MainActor
final class DiscoveryListFocus: ObservableObject {

    struct Request: Equatable {
        let listID: String
        let filmID: String
        let postedAt: Date
    }

    static let shared = DiscoveryListFocus()

    @Published
    private(set) var request: Request?

    func focus(filmID: String, listID: String) {
        request = Request(listID: listID, filmID: filmID, postedAt: .now)
    }

    /// Drops the request (a new player opened).
    func clear() {
        request = nil
    }

    /// The film for `listID`'s page, once, and only while the request is fresh: a page takes its request so it doesn't
    /// scroll again, and a stale one is dropped so a later visit doesn't scroll unexpectedly.
    func take(listID: String) -> String? {
        guard let request, request.listID == listID else { return nil }
        self.request = nil
        return isFocusRequestFresh(postedAt: request.postedAt, now: .now) ? request.filmID : nil
    }
}

extension EnvironmentValues {

    /// Personal fork: the discovery list page a card or row is shown on, so opening its film (from a tap or its menu)
    /// keeps the list, and the film's Watch trailer continues through it.
    @Entry
    var discoveryListID: String? = nil
}
