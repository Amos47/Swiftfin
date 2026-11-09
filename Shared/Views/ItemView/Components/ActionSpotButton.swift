//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import HomeRowsCore
import SwiftUI

// Personal fork: the Play spot's look, shared by the item page's Play button and the actions that take its place.

/// The Play spot's label: accent-tinted glass capsule filling the spot.
struct AccentCapsuleLabel<Content: View>: View {

    @Default(.accentColor)
    private var accentColor

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack {
            content
        }
        .font(.callout)
        .fontWeight(.semibold)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .backport
        .glassEffect(
            .regular.selection(
                tint: accentColor,
                foregroundColor: accentColor.overlayColor
            ),
            in: .capsule
        )
    }
}

/// A server action in the Play spot (Watch trailer on a film page, Watch trailers on a list page), styled like Play.
struct ActionSpotButton: View {

    let action: ItemActionButton
    let isDisabled: Bool
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            AccentCapsuleLabel {
                Image(systemName: action.systemImage)

                Text(action.label)
            }
        }
        .buttonBorderShape(.capsule)
        .buttonStyle(BasicHoverButtonStyle())
        .disabled(isDisabled)
    }
}
