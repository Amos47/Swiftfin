//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import FactoryKit
import HomeRowsCore
import JellyfinAPI
import Logging
import SwiftUI

struct PlayButton: View {

    @Default(.accentColor)
    private var accentColor

    @ObservedObject
    var provider: ItemContentGroupProvider

    @Router
    private var router

    // Personal fork: runs Watch trailer when it takes the Play spot, the same way the action row does.
    @StateObject
    private var actionRunner = ItemActionRunner()

    private var mediaSource: String? {
        guard provider.mediaPlayerItemProvider?.item.mediaSources?.count ?? 0 > 1 else { return nil }
        return provider.mediaPlayerItemProvider?.mediaSource?.displayTitle
    }

    private var mediaSourceSelection: Binding<MediaSourceInfo?> {
        Binding(
            get: { provider.mediaPlayerItemProvider?.mediaSource },
            set: provider.selectMediaSource
        )
    }

    private func play(fromBeginning: Bool = false) {
        #if os(iOS)
        // Personal fork: a downloaded item plays from its file.
        if let item = provider.mediaPlayerItemProvider?.item,
           Container.shared.downloadStore().record(for: item.id)?.isComplete == true
        {
            Task {
                guard let playback = try? await ItemPlaybackResolver.playback(for: item, fromBeginning: fromBeginning) else { return }
                router.route(to: .videoPlayer(provider: playback.provider, queue: playback.queue))
            }
            return
        }
        #endif

        let mediaPlayerItemProvider = if fromBeginning {
            provider.mediaPlayerItemProvider?.modifyingItem {
                $0.userData?.playbackPositionTicks = 0
            }
        } else {
            provider.mediaPlayerItemProvider
        }

        guard let mediaPlayerItemProvider else {
            provider.logger.error("Play selected with no playback item provider")
            return
        }

        let queue: (any MediaPlayerQueue)? = mediaPlayerItemProvider.item.type == .episode ?
            EpisodeMediaPlayerQueue(episode: mediaPlayerItemProvider.item) : nil

        router.route(
            to: .videoPlayer(
                provider: mediaPlayerItemProvider,
                queue: queue
            )
        )
    }

    @ViewBuilder
    private var versionMenu: some View {
        if let mediaSources = provider.mediaPlayerItemProvider?.item.mediaSources,
           mediaSources.count > 1
        {
            Menu {
                Picker(
                    L10n.version,
                    sources: mediaSources,
                    selection: mediaSourceSelection,
                    noneStyle: nil
                )
            } label: {
                #if os(tvOS)
                let shape: Rectangle = .rect
                #else
                let shape: RoundedRectangle = .rect(cornerRadius: 10, style: .circular)
                #endif

                Label {
                    Text(L10n.version)
                } icon: {
                    Image(systemName: "ellipsis")
                        #if os(tvOS)
                            .rotationEffect(.degrees(90))
                        #endif
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .backport
                .glassEffect(
                    .regular.selection(
                        tint: .clear,
                        foregroundColor: .primary
                    ),
                    in: shape
                )
            }
            .foregroundStyle(.primary, .secondary)
            .font(.title3)
            .fontWeight(.semibold)
            .menuStyle(.button)
            .labelStyle(.iconOnly)
            .buttonStyle(BasicHoverButtonStyle())
            #if !os(tvOS)
            .aspectRatio(1, contentMode: .fit)
            #else
            .frame(width: 60)
            #endif
        }
    }

    /// Personal fork: the big button's label in the accent style, shared by Play and the Watch trailer spot.
    private func accentLabel(@ViewBuilder content: () -> some View) -> some View {
        HStack(content: content)
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

    private var playButton: some View {
        Button {
            play()
        } label: {
            accentLabel {
                Image(systemName: "play.fill")

                VStack(spacing: 2) {
                    Text(provider.mediaPlayerItemProvider?.item.playButtonLabel ?? L10n.play)

                    if let mediaSource {
                        Marquee(mediaSource, speed: 40, delay: 3, fade: 5)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
            }
        }
        .buttonBorderShape(.capsule)
        .buttonStyle(BasicHoverButtonStyle())
        .coordinatedFocus(ItemView.Component.play)
        .contextMenu {
            if provider.mediaPlayerItemProvider?.item.userData?.playbackPositionTicks != 0 {
                Button(L10n.playFromBeginning, systemImage: "gobackward") {
                    play(fromBeginning: true)
                }
            }
        }
        .disabled(provider.mediaPlayerItemProvider == nil)
    }

    /// Personal fork: Watch trailer in the Play spot, for a film the user doesn't have. Same style as Play.
    private func watchTrailerSpot(_ action: ItemActionButton) -> some View {
        Button {
            actionRunner.run(action, item: provider.item, listID: provider.discoveryListID) { provider, queue in
                router.route(to: .videoPlayer(provider: provider, queue: queue))
            }
        } label: {
            accentLabel {
                Image(systemName: action.systemImage)

                Text(action.label)
            }
        }
        .buttonBorderShape(.capsule)
        .buttonStyle(BasicHoverButtonStyle())
        .coordinatedFocus(ItemView.Component.play)
        .disabled(actionRunner.isRunning)
    }

    /// Personal fork: a film the user doesn't have and the server has no trailer for: plainly grey, not a dimmed Play.
    private var notInLibraryButton: some View {
        Button {} label: {
            Text(L10n.notInYourLibrary)
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .backport
                .glassEffect(
                    .regular.tint(.gray.opacity(0.3)).interactive(false),
                    in: .capsule
                )
        }
        .buttonBorderShape(.capsule)
        .buttonStyle(BasicHoverButtonStyle())
        .coordinatedFocus(ItemView.Component.play)
        .disabled(true)
    }

    var body: some View {
        HStack(alignment: .center, spacing: UIDevice.isTV ? 30 : 10) {
            switch provider.playSpot {
            case .play:
                playButton

                versionMenu
            case .watchTrailer:
                if let action = provider.playSpotAction {
                    watchTrailerSpot(action)
                }
            case .notInLibrary:
                notInLibraryButton
            }
        }
        .frame(height: UIDevice.isTV ? 75 : 44)
        .errorMessage($actionRunner.error)
        .onDisappear {
            actionRunner.cancel()
        }
    }
}
