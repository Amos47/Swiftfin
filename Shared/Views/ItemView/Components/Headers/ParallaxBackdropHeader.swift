//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

// Personal fork: the compact enhanced header's backdrop, shared with the discovery list page.

/// The width-to-height ratio of the compact header's backdrop, shared by the film page and the discovery list page.
let parallaxBackdropHeaderAspectRatio: CGFloat = 1.6

/// A backdrop behind `overlay` with a parallax scroll, mirrored up under the navigation bar and fading at the bottom
/// into the image's own colour. The overlay is drawn dark.
struct ParallaxBackdropHeader<Overlay: View>: View {

    let imageSource: ImageSource
    let aspectRatio: CGFloat
    private let overlay: Overlay

    init(imageSource: ImageSource, aspectRatio: CGFloat = parallaxBackdropHeaderAspectRatio, @ViewBuilder overlay: () -> Overlay) {
        self.imageSource = imageSource
        self.aspectRatio = aspectRatio
        self.overlay = overlay()
    }

    /// Picks the image's colour off the main thread for the bottom fade.
    private static func resolveColor(from image: UIImage, binding: Binding<Color>) {
        Task.detached(priority: .utility) {
            guard let color = image.interestingColor() else { return }

            await MainActor.run {
                binding.wrappedValue = color
            }
        }
    }

    var body: some View {
        overlay
            .edgePadding(.horizontal)
            .frame(maxWidth: .infinity)
            .colorScheme(.dark)
            .backgroundParallaxHeader(multiplier: 0.3) {
                StateAdapter(initialValue: Color.secondarySystemFill) { resolvedColor in
                    MirrorExtensionView(edges: .top) {
                        AlternateLayoutView {
                            Color.clear
                        } content: {
                            ImageView(imageSource)
                                .image { (image: UIImage) in
                                    Image(uiImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .onAppear {
                                            Self.resolveColor(from: image, binding: resolvedColor)
                                        }
                                }
                        }
                        .aspectRatio(aspectRatio, contentMode: .fit)
                        .accessibilityHidden(true)
                    }
                    .bottomEdgeGradient(bottomColor: resolvedColor.wrappedValue)
                }
            }
    }
}
