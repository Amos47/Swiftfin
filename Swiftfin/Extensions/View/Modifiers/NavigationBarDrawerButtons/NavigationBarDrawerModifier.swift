//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

struct NavigationBarFilterDrawerModifier: ViewModifier {

    @ObservedObject
    var viewModel: FilterViewModel

    let types: [ItemFilterType]

    private var drawer: some View {
        NavigationBarFilterDrawer(
            viewModel: viewModel,
            types: types
        )
    }

    func body(content: Content) -> some View {
        if types.isEmpty {
            content
        } else {
            if #available(iOS 26, *) {
                // Personal fork: a solid bar pinned under the title. `safeAreaBar` is see-through and, on iOS 26.5,
                // floats down over the content.
                content
                    .safeAreaInset(edge: .top, spacing: 0) {
                        drawer
                            .padding(.top, 5)
                            .background {
                                Color(uiColor: .systemBackground)
                                    .ignoresSafeArea(edges: .top)
                            }
                    }
            } else {
                NavigationBarDrawerView {
                    drawer
                        .ignoresSafeArea()
                } content: {
                    content
                }
                .ignoresSafeArea()
            }
        }
    }
}
