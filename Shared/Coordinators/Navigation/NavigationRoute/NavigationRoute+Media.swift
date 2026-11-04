//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import FactoryKit
import JellyfinAPI
import PreferencesView
import SwiftUI
import Transmission

extension NavigationRoute {

    @MainActor
    static var liveTV: NavigationRoute {
        NavigationRoute(
            id: "liveTV",
            withNamespace: { .push(.zoom(sourceID: "item", namespace: $0)) }
        ) {
            ContentGroupView(provider: LiveTVGroupProvider())
        }
    }

    static func mediaSourceInfo(source: MediaSourceInfo) -> NavigationRoute {
        NavigationRoute(
            id: "mediaSourceInfo",
            style: .sheet
        ) {
            MediaSourceInfoView(source: source)
        }
    }

    static func mediaStreamInfo(mediaStream: MediaStream) -> NavigationRoute {
        NavigationRoute(id: "mediaStreamInfo") {
            MediaStreamInfoView(mediaStream: mediaStream)
        }
    }

    @MainActor
    static func videoPlayer(
        provider: MediaPlayerItemProvider,
        queue: (any MediaPlayerQueue)? = nil
    ) -> NavigationRoute {
        let manager = MediaPlayerManager(
            provider: provider,
            queue: queue
        )

        return Self.videoPlayer(manager: manager)
    }

    @MainActor
    static func videoPlayer(manager: MediaPlayerManager) -> NavigationRoute {

        Container.shared.mediaPlayerManager.register {
            manager
        }

        Container.shared.mediaPlayerManagerPublisher()
            .send(manager)

        return NavigationRoute(
            id: "videoPlayer",
            style: .fullscreen
        ) {
            VideoPlayerViewShim(manager: manager)
        }
    }
}

// TODO: shim until native vs swiftfin player is replace with vlc vs av layers
//       - when removed, ensure same behavior with safe area
//       - may just need to make a VC wrapper to capture them

struct VideoPlayerViewShim: View {

    @State
    private var safeAreaInsets: EdgeInsets = .init()

    let manager: MediaPlayerManager

    #if os(iOS)
    @State
    private var usesAppleEngine: Bool
    @State
    private var wasPlayingWhenInactive = false
    #endif

    init(manager: MediaPlayerManager) {
        self.manager = manager
        #if os(iOS)
        self._usesAppleEngine = State(initialValue: PlaybackEngine.usesAppleEngine(for: manager.item))
        #endif
    }

    var body: some View {
        Group {
            #if os(iOS)
            // Personal fork: iOS always uses Swiftfin's controls, on Apple's engine or VLC (`PlaybackEngine`).
            if usesAppleEngine {
                VideoPlayer {
                    AVMediaPlayerProxy()
                } onSwitchToVLC: {
                    usesAppleEngine = false
                }
                .id("apple")
            } else {
                VideoPlayer()
                    .id("vlc")
            }
            #else
            if Defaults[.VideoPlayer.videoPlayerType] == .swiftfin {
                VideoPlayer()
            } else {
                NativeVideoPlayer()
            }
            #endif
        }
        .colorScheme(.dark) // use over `preferredColorScheme(.dark)` to not have destination change
        .environment(\.safeAreaInsets, safeAreaInsets)
        .supportedOrientations(.allButUpsideDown)
        .ignoresSafeArea()
        .persistentSystemOverlays(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .onSceneDidEnterBackground {
            #if os(iOS)
            // Personal fork: Picture in Picture keeps playing in the background.
            if let appleProxy = manager.proxy as? AVMediaPlayerProxy, appleProxy.keepsPlayingInBackground {
                return
            }
            #endif
            if Defaults[.VideoPlayer.Transition.pauseOnBackground] {
                manager.setPlaybackRequestStatus(status: .paused)
            }
        }
        #if os(iOS)
        // Personal fork: VLC can come back from the app switcher with a frozen picture over live audio. Seeking to
        // the current position redraws it.
        .onScenePhase(.inactive) {
            wasPlayingWhenInactive = manager.playbackRequestStatus == .playing
        }
        .onScenePhase(.active) {
            if wasPlayingWhenInactive, manager.proxy is VLCMediaPlayerProxy {
                manager.proxy?.setSeconds(manager.seconds)
            }
            wasPlayingWhenInactive = false
        }
        #endif
        .onFrameChanged { _, safeArea in
            self.safeAreaInsets = safeArea.max(EdgeInsets.edgePadding)
        }
    }
}
