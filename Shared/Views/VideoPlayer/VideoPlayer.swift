//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import HomeRowsCore
import SwiftUI
import Transmission

struct VideoPlayer: View {

    @Environment(\.presentationCoordinator)
    private var presentationCoordinator

    @InjectedObject(\.mediaPlayerManager)
    private var manager: MediaPlayerManager

    @LazyState
    private var proxy: any VideoMediaPlayerProxy

    @Router
    private var router

    // TODO: move audio/subtitle offset to container state?
    @State
    private var audioOffset: Duration = .zero
    @State
    private var isBeingDismissedByTransition = false

    // TODO: move behavior to `PlaybackProgress`?
    @State
    private var scrubbingStartTime: CFTimeInterval? = nil
    @State
    private var subtitleOffset: Duration = .zero

    @StateObject
    private var containerState: VideoPlayerContainerState = .init()

    // Personal fork: the engine is injected so iOS can play on Apple's AVPlayer, and can ask to switch to VLC.
    private let onSwitchToVLC: (() -> Void)?

    init(
        makeProxy: @escaping @MainActor () -> any VideoMediaPlayerProxy = { VLCMediaPlayerProxy() },
        onSwitchToVLC: (() -> Void)? = nil
    ) {
        self._proxy = .init(wrappedValue: makeProxy())
        self.onSwitchToVLC = onSwitchToVLC
    }

    var body: some View {
        VideoPlayerContainerView(
            containerState: containerState,
            manager: manager
        ) {
            proxy.videoPlayerBody
                .eraseToAnyView()
        } playbackControls: {
            PlaybackControls()
        }
        .onAppear {
            // Personal fork: the AVPlayer engine updates the progress bar through the container state.
            (proxy as? AVMediaPlayerProxy)?.containerState = containerState
            #if os(iOS)
            (proxy as? AVMediaPlayerProxy)?.setUpPictureInPicture()
            // Personal fork: a new player drops any list scroll left over from an earlier close.
            DiscoveryListFocus.shared.clear()
            #endif
            manager.proxy = proxy

            // Personal fork: a player replacing another engine mid-item rebuilds the item at its position.
            #if os(iOS)
            if manager.playbackItem != nil, let provider = manager.currentItemProvider() {
                manager.playNewItem(provider: provider)
                if proxy is VLCMediaPlayerProxy {
                    containerState.toastProxy.present(L10n.playingWithVLC)
                }
            } else {
                manager.start()
            }
            #else
            manager.start()
            #endif
        }
        .prefersStatusBarHidden(!containerState.isPresentingOverlay)
        .onChange(of: audioOffset) {
            if let proxy = proxy as? MediaPlayerOffsetConfigurable {
                proxy.setAudioOffset(audioOffset)
            }
        }
        .onChange(of: containerState.isAspectFilled) {
            UIView.animate(withDuration: 0.2) {
                proxy.setAspectFill(containerState.isAspectFilled)
            }
        }
        .onChange(of: containerState.isScrubbing) {
            if containerState.isScrubbing {
                scrubbingStartTime = CACurrentMediaTime()
            }

            guard let scrubbingStartTime else { return }
            let scrubbingDelta = CACurrentMediaTime() - scrubbingStartTime
            let secondsDelta = abs(manager.seconds - containerState.scrubbedSeconds.value)

            guard secondsDelta >= .seconds(1), scrubbingDelta >= 0.1 else { return }

            let scrubbedSeconds = containerState.scrubbedSeconds.value
            manager.seconds = scrubbedSeconds
            proxy.setSeconds(scrubbedSeconds)
        }
        .onChange(of: subtitleOffset) {
            if let proxy = proxy as? MediaPlayerOffsetConfigurable {
                proxy.setSubtitleOffset(subtitleOffset)
            }
        }
        .preference(
            key: PresentationControllerShouldDismissPreferenceKey.self,
            value: containerState.presentationControllerShouldDismiss
        )
        .onChange(of: presentationCoordinator.isPresented) {
            guard !presentationCoordinator.isPresented else { return }
            isBeingDismissedByTransition = true
            manager.stop()
        }
        .onReceive(manager.$playbackItem) { newItem in
            containerState.isAspectFilled = false
            audioOffset = .zero
            subtitleOffset = .zero

            // TODO: move to container view
            containerState.scrubbedSeconds.value = newItem?.baseItem.startSeconds ?? .zero
        }
        .onReceive(manager.$state) { newState in
            #if os(iOS)
            if newState == .stopped {
                if !showFilmAfterClosing() {
                    showSeriesAfterClosing()
                }
                PlaybackEngine.vlcFallbackItemIDs.removeAll()
            }
            #endif
            if newState == .stopped, !isBeingDismissedByTransition {
                router.dismiss()
            }
        }

        .alert(
            L10n.error,
            isPresented: .constant(manager.error != nil)
        ) {
            Button(L10n.close, role: .cancel) {
                Container.shared.mediaPlayerManager.reset()
                router.dismiss()
            }
        } message: {
            Text(L10n.unableToLoadThisItem)
        }
        #if os(iOS)
        .modifier(appleEngineFallback)
        #endif
    }

    #if os(iOS)
    /// Personal fork: closing a trailer queue that moved on to another film lands on that film's page, on top of where
    /// the queue started (or back at it, when it's already in the path); a list page underneath scrolls to the film. False when the queue
    /// names no other film (an
    /// older server, an episode), so the usual close applies.
    private func showFilmAfterClosing() -> Bool {
        guard let target = manager.queue?.closeTarget(for: manager.item),
              let presenter = router.router.navigationCoordinator?.presenter
        else { return false }

        if let listID = target.listID {
            DiscoveryListFocus.shared.focus(filmID: target.filmID, listID: listID)
        }

        let filmRoute = NavigationRoute.item(id: target.filmID, discoveryListID: target.listID)
        switch closeNavigation(targetID: filmRoute.id, pathIDs: presenter.path.map(\.id)) {
        case .stay:
            break
        case let .popTo(index):
            presenter.path.removeSubrange((index + 1)...)
        case .push:
            presenter.push(filmRoute)
        }
        return true
    }

    /// Personal fork: closing an episode lands on its series page, unless that's where playback started.
    private func showSeriesAfterClosing() {
        let item = manager.item
        guard item.type == .episode, let seriesID = item.seriesID,
              let presenter = router.router.navigationCoordinator?.presenter
        else { return }

        let seriesRoute = NavigationRoute.item(id: seriesID)
        guard presenter.path.last?.id != seriesRoute.id else { return }
        presenter.push(seriesRoute)
    }

    private var appleEngineFallback: some ViewModifier {
        OptionalAppleEngineFallback(proxy: proxy as? AVMediaPlayerProxy, manager: manager) {
            onSwitchToVLC?()
        }
    }
    #endif
}

#if os(iOS)
private struct OptionalAppleEngineFallback: ViewModifier {

    let proxy: AVMediaPlayerProxy?
    let manager: MediaPlayerManager
    let onSwitchToVLC: () -> Void

    func body(content: Content) -> some View {
        if let proxy {
            content.modifier(AppleEngineFallbackModifier(proxy: proxy, manager: manager, onSwitchToVLC: onSwitchToVLC))
        } else {
            content
        }
    }
}
#endif
