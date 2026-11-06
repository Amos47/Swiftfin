//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import JellyfinAPI
import SwiftUI

#if os(iOS)
import PlayerCore

// Personal fork: acts on the Apple engine's fallback requests (retry, switch to VLC, or offer VLC).

struct AppleEngineFallbackModifier: ViewModifier {

    @ObservedObject
    var proxy: AVMediaPlayerProxy
    let manager: MediaPlayerManager
    let onSwitchToVLC: () -> Void

    @State
    private var isOfferingVLC = false
    @State
    private var isShowingError = false

    func body(content: Content) -> some View {
        content
            .onReceive(proxy.$fallbackRequest) { request in
                // Downloads never go to VLC.
                let request = manager.playbackItem?.isDownloaded == true ? downloadFallbackDecision(request) : request

                switch request {
                case .none:
                    break
                case .retryApple:
                    if let provider = manager.currentItemProvider() {
                        manager.playNewItem(provider: provider)
                    }
                case .switchToVLC:
                    switchToVLC()
                case .offerVLC:
                    isOfferingVLC = true
                case .showError:
                    isShowingError = true
                }
            }
            .alert(L10n.error, isPresented: $isOfferingVLC) {
                Button(L10n.playWithVLC) {
                    switchToVLC()
                }
                Button(L10n.close, role: .cancel) {
                    manager.stop()
                }
            } message: {
                Text(L10n.unableToLoadThisItem)
            }
            .alert(L10n.error, isPresented: $isShowingError) {
                Button(L10n.close, role: .cancel) {
                    manager.stop()
                }
            } message: {
                Text(L10n.unableToLoadThisItem)
            }
    }

    private func switchToVLC() {
        if let id = manager.item.id {
            PlaybackEngine.vlcFallbackItemIDs.insert(id)
        }
        proxy.stop()
        onSwitchToVLC()
    }
}
#endif

extension MediaPlayerManager {

    /// Rebuilds the current item at the current position, for the engine `PlaybackEngine` now picks for it.
    func currentItemProvider() -> MediaPlayerItemProvider? {
        guard let playbackItem else { return nil }

        let mediaSource = playbackItem.mediaSource
        let audioStreamIndex = playbackItem.selectedAudioStreamIndex
        let subtitleStreamIndex = playbackItem.selectedSubtitleStreamIndex
        let positionTicks = seconds.ticks

        #if os(iOS)
        // Personal fork: a download reloads from its file.
        if playbackItem.isDownloaded, let record = Container.shared.downloadStore().record(for: playbackItem.baseItem.id) {
            return record.playerItemProvider.modifyingItem { $0.userData?.playbackPositionTicks = positionTicks }
        }
        #endif

        return MediaPlayerItemProvider(item: playbackItem.baseItem, mediaSource: mediaSource) { item, modifyItem in
            try await MediaPlayerItem.build(
                for: item,
                mediaSource: mediaSource,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex,
                modifyItem: modifyItem
            )
        }
        .modifyingItem { item in
            if item.userData == nil {
                item.userData = UserItemDataDto(key: "")
            }
            item.userData?.playbackPositionTicks = positionTicks
        }
    }
}
