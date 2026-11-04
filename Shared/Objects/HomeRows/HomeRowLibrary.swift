//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import HomeRowsCore
import JellyfinAPI

// Personal fork: Custom Home Rows.

/// The items of one server home row. The server returns the row's first page; there are no further pages.
struct HomeRowLibrary: PagingLibrary {

    /// Holds the first page loaded with the layout; the first `retrievePage` uses it instead of fetching again.
    final class Seed: @unchecked Sendable {
        var items: [BaseItemDto]?

        init(_ items: [BaseItemDto]?) {
            self.items = items
        }
    }

    let hasNextPage: Bool = false
    let parent: TitledLibraryParent
    let rowID: UUID
    private let seed: Seed

    init(rowID: UUID, title: String, initialItems: [BaseItemDto]? = nil) {
        self.rowID = rowID
        self.parent = .init(displayTitle: title, id: "home-row-\(rowID.uuidString)")
        self.seed = Seed(initialItems)
    }

    func retrievePage(
        environment: Empty,
        pageState: LibraryPageState
    ) async throws -> [BaseItemDto] {
        guard pageState.pageOffset == 0 else { return [] }

        if let items = seed.items {
            seed.items = nil
            return items
        }

        let items = try await HomeRowsService.api(for: pageState.userSession).items(rowID: rowID, limit: pageState.pageSize)
        return items.error == nil ? items.items : []
    }

    func onItemUserDataChanged(
        viewModel: PagingLibraryViewModel<HomeRowLibrary>,
        userData: UserItemDataDto
    ) {
        viewModel.scheduleRefreshForItemUserData(minimumInterval: 3)
    }
}
