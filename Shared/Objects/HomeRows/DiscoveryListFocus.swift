//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation

// Personal fork: discovery list pages.

/// The film a list page should scroll to: closing the player on a trailer queue from that list names the film that was
/// playing, and the list page underneath (if any) scrolls to it.
@MainActor
final class DiscoveryListFocus: ObservableObject {

    struct Request: Equatable {
        let listID: String
        let filmID: String
    }

    static let shared = DiscoveryListFocus()

    @Published
    private(set) var request: Request?

    func focus(filmID: String, listID: String) {
        request = Request(listID: listID, filmID: filmID)
    }

    /// The film for `listID`'s page, once: a page takes its request so it doesn't scroll again on a later visit.
    func take(listID: String) -> String? {
        guard let request, request.listID == listID else { return nil }
        self.request = nil
        return request.filmID
    }
}
