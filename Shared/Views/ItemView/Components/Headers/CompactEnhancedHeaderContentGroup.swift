//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI
import SwiftUI

extension ItemView {

    struct CompactEnhancedHeaderContentGroup: ContentGroup {

        let id: String = ItemView.Component.header
        let provider: ItemContentGroupProvider
        /// Personal fork: the iPhone series page shows its details below the header instead.
        var showsDetails = true

        func body(with viewModel: Empty) -> Body {
            Body(provider: provider, showsDetails: showsDetails)
        }

        struct Body: View {

            @ObservedObject
            var provider: ItemContentGroupProvider
            var showsDetails = true

            @StoredValue(.User.itemViewAttributes)
            private var attributes

            private let headerAspectRatio = 1.6

            private var logo: some View {
                ImageView(
                    provider.item.imageSource(
                        .logo,
                        environment: ImageSourceOptions(maxHeight: 70)
                    )
                )
                .placeholder { _ in
                    EmptyView()
                }
                .failure {
                    Text(provider.item.displayTitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                }
                .aspectRatio(contentMode: .fit)
                .frame(height: 70, alignment: .bottom)
                .accessibilityLabel(provider.item.displayTitle)
                .accessibilityRemoveTraits(.isImage)
            }

            private var overlay: some View {
                VStack(alignment: .center, spacing: 10) {
                    AlternateLayoutView(alignment: .bottom) {
                        Color.clear
                            .aspectRatio(headerAspectRatio, contentMode: .fit)
                    } content: {
                        logo
                    }
                    .zIndex(10)

                    VStack(alignment: .center, spacing: 10) {
                        if showsDetails {
                            MetadataHStack(item: provider.item)

                            VStack(alignment: .center, spacing: 5) {
                                if provider.item.presentPlayButton {
                                    PlayButton(provider: provider)
                                }

                                ItemView.ActionButtonHStack(provider: provider)
                            }
                            .frame(maxWidth: 300)

                            ItemView.Description(item: provider.item)

                            ItemView.AttributesHStack(
                                attributes: attributes,
                                item: provider.item,
                                selectedMediaSource: provider.mediaPlayerItemProvider?.mediaSource,
                                alignment: .leading
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .edgePadding(.bottom)
                    .background(
                        alignment: .bottom,
                        extendedBy: .init(
                            vertical: 25,
                            horizontal: EdgeInsets.edgePadding
                        )
                    ) {
                        Rectangle()
                            .fill(Material.ultraThin)
                            .mask(gradient: .eased(.easeOut)) {
                                (location: 0, opacity: 0)
                                (location: 0.2, opacity: 1)
                            }
                    }
                    .zIndex(9)
                }
            }

            // Personal fork: the backdrop is shared with the discovery list page.
            var body: some View {
                ParallaxBackdropHeader(
                    imageSource: provider.item.imageSource(.backdrop, environment: ImageSourceOptions(maxWidth: 1320)),
                    aspectRatio: headerAspectRatio
                ) {
                    overlay
                }
            }
        }
    }
}
