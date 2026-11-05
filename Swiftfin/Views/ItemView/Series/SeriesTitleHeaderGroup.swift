//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

// Personal fork: the iPhone series page's header when the show has no backdrop art: just its title.

struct SeriesTitleHeaderGroup: ContentGroup {

    let id: String = ItemView.Component.header
    let item: BaseItemDto

    func body(with viewModel: Empty) -> some View {
        Text(item.displayTitle)
            .font(.largeTitle)
            .fontWeight(.bold)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .edgePadding(.horizontal)
    }
}
