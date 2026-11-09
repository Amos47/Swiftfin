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
import SwiftUI

// Personal fork: Custom Home Rows.

/// A server home row drawn as a poster row. Episodes always show their own image here, whatever the "use series
/// backdrop" setting says, matching the web and Android TV clients.
struct HomeRowPosterGroup: ContentGroup {

    let group: PosterGroup<HomeRowLibrary>

    var id: String {
        group.id
    }

    var viewModel: PagingLibraryViewModel<HomeRowLibrary> {
        group.viewModel
    }

    var _shouldBeResolved: Bool {
        group._shouldBeResolved
    }

    func body(with viewModel: PagingLibraryViewModel<HomeRowLibrary>) -> some View {
        group.body(with: viewModel)
            .environment(\.useSeriesLandscapeBackdrop, false)
    }
}

/// The home screen groups for the server's home rows, in layout order.
@MainActor
func homeRowGroups(_ rows: [LoadedHomeRow]) -> [any ContentGroup] {
    rows.map { loaded -> any ContentGroup in
        let library = HomeRowLibrary(rowID: loaded.row.id, title: loaded.title, initialItems: loaded.items.items)

        switch loaded.style {
        case .libraryButtons, .libraryTiles:
            return PillGroup(
                displayTitle: loaded.title,
                id: "home-row-\(loaded.row.id.uuidString)",
                elements: loaded.items.items.map(UserViewLibraryElement.userView)
            ) { router, element in
                guard case let .userView(item) = element else { return }
                if item.collectionType == .livetv {
                    router.route(to: .liveTV)
                } else {
                    router.route(to: .library(library: ItemLibrary(parent: item, filters: .default)))
                }
            }
        case .landscape, .portrait, .square:
            let (displayType, size): (PosterDisplayType, PosterDisplayType.Size) = switch loaded.style {
            case .portrait: (.portrait, .small)
            case .square: (.square, .small)
            default: (.landscape, .medium)
            }
            var environment = PosterGroup<HomeRowLibrary>.Environment.default
            #if os(iOS)
            // A discovery row's title and See all open its list page; without `PageListId` (an older server) the row
            // keeps its own See all.
            if let listID = loaded.items.presentation.pageListID {
                environment.headerRoute = .discoveryList(listID: listID, title: loaded.title)
            }
            #endif
            return HomeRowPosterGroup(
                group: PosterGroup(
                    id: "home-row-\(loaded.row.id.uuidString)",
                    library: library,
                    posterDisplayType: displayType,
                    posterSize: size,
                    environment: environment
                )
            )
        }
    }
}
