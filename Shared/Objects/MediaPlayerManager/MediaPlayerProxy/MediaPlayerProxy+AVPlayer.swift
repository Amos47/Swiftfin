//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import Combine
import Defaults
import Foundation
@preconcurrency import JellyfinAPI
import SwiftUI

#if os(iOS)
import AVKit
import PlayerCore
#endif

// Personal fork: completed so the AVPlayer engine can drive Swiftfin's own controls on iOS (progress, buffering, end of
// item, rate, audio/subtitle selection). `NativeVideoPlayer` (tvOS's AVPlayerViewController) still uses it unchanged.

// TODO: report playback information, see VLCUI.PlaybackInformation (dropped frames, etc.)

@MainActor
class AVMediaPlayerProxy: VideoMediaPlayerProxy {

    let isBuffering: PublishedBox<Bool> = .init(initialValue: false)
    var videoSize: PublishedBox<CGSize> = .init(initialValue: .zero)
    let droppedFrames: PublishedBox<Int> = .init(initialValue: 0)
    let corruptedFrames: PublishedBox<Int> = .init(initialValue: 0)

    let avPlayerLayer: AVPlayerLayer
    let player: AVPlayer

    /// Set by `AVPlayerView` when hosted in Swiftfin's controls; nil under `NativeVideoPlayer`.
    weak var containerState: VideoPlayerContainerState?

    /// Whether the current item has shown a frame; used for the fallback rules.
    @Published
    private(set) var hasFirstFrame = false

    private var itemObservers: [NSKeyValueObservation] = []
    private var readyForDisplayObserver: NSKeyValueObservation?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var managerItemObserver: AnyCancellable?
    private var managerStateObserver: AnyCancellable?
    private var managerRateObserver: AnyCancellable?
    private var didStartCurrentItem = false

    #if os(iOS)
    /// What the player should do after the Apple engine failed; the view acts on it (`VideoPlayer`).
    @Published
    private(set) var fallbackRequest: FallbackDecision = .none
    @Published
    private(set) var isPictureInPictureActive = false

    private var pictureInPictureController: AVPictureInPictureController?
    private var pictureInPictureDelegate: PictureInPictureDelegate?
    private var firstFrameWatch: Task<Void, Never>?
    private var retriedItemID: String?
    private var currentItemID: String?

    /// Leaving the app keeps playing: Picture in Picture is running or about to start.
    var keepsPlayingInBackground: Bool {
        isPictureInPictureActive || (pictureInPictureController?.isPictureInPicturePossible ?? false)
    }
    #endif

    weak var manager: MediaPlayerManager? {
        didSet {
            for var o in observers {
                o.manager = manager
            }

            if let manager {
                managerItemObserver = manager.$playbackItem
                    .sink { [weak self] playbackItem in
                        if let playbackItem {
                            self?.playNew(item: playbackItem)
                        }
                    }

                managerStateObserver = manager.$state
                    .sink { [weak self] state in
                        switch state {
                        case .stopped:
                            self?.playbackStopped()
                        default: break
                        }
                    }

                #if os(iOS)
                managerRateObserver = manager.$rate
                    .sink { [weak self] rate in
                        self?.setRate(rate)
                    }
                #endif
            } else {
                managerItemObserver?.cancel()
                managerStateObserver?.cancel()
                managerRateObserver?.cancel()
            }
        }
    }

    var observers: [any MediaPlayerObserver] = [
        NowPlayableObserver(),
    ]

    init() {
        self.player = AVPlayer()
        self.avPlayerLayer = AVPlayerLayer(player: player)

        #if os(iOS)
        // The app chooses tracks from the user's Jellyfin settings, not iOS's.
        player.appliesMediaSelectionCriteriaAutomatically = false
        #endif

        readyForDisplayObserver = avPlayerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            let isReady = layer.isReadyForDisplay
            DispatchQueue.main.async {
                if isReady {
                    self?.hasFirstFrame = true
                }
            }
        }

        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let timeControlStatus = player.timeControlStatus

            DispatchQueue.main.async {
                guard let self else { return }
                switch timeControlStatus {
                case .paused:
                    self.isBuffering.value = false
                    self.manager?.setPlaybackRequestStatus(status: .paused)
                case .waitingToPlayAtSpecifiedRate:
                    self.isBuffering.value = true
                case .playing:
                    self.isBuffering.value = false
                    self.manager?.setPlaybackRequestStatus(status: .playing)
                @unknown default: ()
                }
            }
        }
    }

    func play() {
        player.playImmediately(atRate: manager?.rate ?? 1)
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.pause()
    }

    func jumpForward(_ seconds: Duration) {
        let currentTime = player.currentTime()
        let newTime = currentTime + CMTime(seconds: seconds.seconds, preferredTimescale: 1000)
        player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func jumpBackward(_ seconds: Duration) {
        let currentTime = player.currentTime()
        let newTime = max(.zero, currentTime - CMTime(seconds: seconds.seconds, preferredTimescale: 1000))
        player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setSeconds(_ seconds: Duration) {
        let time = CMTime(seconds: seconds.seconds, preferredTimescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ rate: Float) {
        player.defaultRate = rate
        if player.timeControlStatus != .paused {
            player.rate = rate
        }
    }

    // MARK: - Tracks

    /// Jellyfin audio switches always rebuild the stream (its HLS carries one audio track); nothing to do in place.
    func setAudioStream(_ stream: MediaStream) {}

    /// Selects the subtitle rendition for the Jellyfin stream index in `stream`, or none for -1.
    ///
    /// Jellyfin lists every text subtitle of the source in the manifest, in source order, once a subtitle was requested
    /// over HLS. So the n-th legible option is the n-th text subtitle stream.
    func setSubtitleStream(_ stream: MediaStream) {
        guard let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible)
        else { return }

        let options = group.options.filter { $0.mediaType == .subtitle }
        let textIndexes = manager?.playbackItem?.textSubtitleStreamIndexes ?? []

        guard let index = stream.index, index != -1,
              let position = textIndexes.firstIndex(of: index),
              options.indices.contains(position)
        else {
            item.select(nil, in: group)
            return
        }

        item.select(options[position], in: group)
    }

    func setAspectFill(_ aspectFill: Bool) {
        avPlayerLayer.videoGravity = aspectFill ? .resizeAspectFill : .resizeAspect
    }

    var videoPlayerBody: some View {
        AVPlayerView()
            .environmentObject(self)
    }
}

extension AVMediaPlayerProxy {

    private func removeItemObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        itemObservers.forEach { $0.invalidate() }
        itemObservers = []
    }

    private func playbackStopped() {
        player.pause()
        removeItemObservers()
        #if os(iOS)
        firstFrameWatch?.cancel()
        #endif
    }

    private func playNew(item: MediaPlayerItem) {
        removeItemObservers()

        let baseItem = item.baseItem
        var url = item.url
        #if DEBUG
        // Launch argument for testing the VLC fallback.
        if ProcessInfo.processInfo.arguments.contains("-forceAppleEngineFailure") {
            url = URL(string: "http://127.0.0.1:9/fail.m3u8")!
        }
        #endif
        let newAVPlayerItem = AVPlayerItem(url: url)
        newAVPlayerItem.externalMetadata = item.baseItem.avMetadata

        hasFirstFrame = false
        didStartCurrentItem = false
        player.replaceCurrentItem(with: newAVPlayerItem)

        #if os(iOS)
        if currentItemID != baseItem.id {
            retriedItemID = nil
        }
        currentItemID = baseItem.id
        fallbackRequest = .none
        watchForFirstFrame()
        #endif

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 1000),
            queue: .main
        ) { [weak self] newTime in
            guard newTime.isNumeric else { return }
            let newSeconds = Duration.seconds(newTime.seconds)

            MainActor.assumeIsolated {
                guard let self else { return }
                if let containerState = self.containerState, !containerState.isScrubbing {
                    containerState.scrubbedSeconds.value = newSeconds
                }

                self.manager?.seconds = newSeconds
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: newAVPlayerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let manager = self?.manager, manager.playbackItem?.baseItem.isLiveStream == false else { return }
                manager.ended()
            }
        }

        itemObservers.append(newAVPlayerItem.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            DispatchQueue.main.async {
                self?.videoSize.value = size
            }
        })

        itemObservers.append(newAVPlayerItem.observe(\.status, options: [.new, .initial]) { [weak self] avItem, _ in
            let status = avItem.status
            DispatchQueue.main.async {
                guard let self else { return }

                switch status {
                case .failed:
                    #if os(iOS)
                    self.evaluateFallback(failed: true, secondsWithoutFirstFrame: 0)
                    #else
                    if let error = self.player.error ?? avItem.error {
                        self.manager?.error(ErrorMessage("AVPlayer error: \(error.localizedDescription)"))
                    }
                    #endif
                case .readyToPlay:
                    guard !self.didStartCurrentItem else { return }
                    self.didStartCurrentItem = true

                    #if os(iOS)
                    let selectedSubtitle = item.selectedSubtitleStreamIndex ?? -1
                    self.setSubtitleStream(MediaStream(index: selectedSubtitle))
                    #endif

                    let resumeOffset = Duration.seconds(Defaults[.VideoPlayer.resumeOffset])
                    let startSeconds = max(.zero, (baseItem.startSeconds ?? .zero) - resumeOffset)

                    self.player.seek(
                        to: CMTime(seconds: startSeconds.seconds, preferredTimescale: 1000),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    ) { [weak self] _ in
                        DispatchQueue.main.async {
                            self?.play()
                        }
                    }
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        })
    }
}

#if os(iOS)

// MARK: - Fallback and Picture in Picture

extension AVMediaPlayerProxy {

    /// Mid-playback failures retry Apple once per item, then offer VLC; start-up failures switch to VLC.
    private func evaluateFallback(failed: Bool, secondsWithoutFirstFrame: Double) {
        let decision = fallbackDecision(
            failed: failed,
            secondsWithoutFirstFrame: secondsWithoutFirstFrame,
            isBuffering: isBuffering.value,
            hadFirstFrame: hasFirstFrame,
            alreadyRetried: retriedItemID != nil && retriedItemID == currentItemID,
            isPictureInPictureActive: isPictureInPictureActive
        )

        guard decision != .none else { return }

        if decision == .retryApple {
            retriedItemID = currentItemID
        }

        firstFrameWatch?.cancel()
        manager?.logger.warning("Apple engine fallback: \(String(describing: decision))")
        fallbackRequest = decision
    }

    private func watchForFirstFrame() {
        firstFrameWatch?.cancel()
        let started = Date.now

        firstFrameWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, !self.hasFirstFrame else { return }
                self.evaluateFallback(failed: false, secondsWithoutFirstFrame: Date.now.timeIntervalSince(started))
            }
        }
    }

    /// Starts Picture in Picture automatically when the app goes to the background.
    func setUpPictureInPicture() {
        guard pictureInPictureController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }

        let delegate = PictureInPictureDelegate(proxy: self)
        let controller = AVPictureInPictureController(playerLayer: avPlayerLayer)
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        controller?.delegate = delegate

        pictureInPictureController = controller
        pictureInPictureDelegate = delegate
    }

    fileprivate func pictureInPictureChanged(isActive: Bool, closedByUser: Bool) {
        isPictureInPictureActive = isActive

        // Closing the PiP window stops playback, like the player's close button.
        if closedByUser {
            manager?.stop()
        }
    }

    private final class PictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate {

        weak var proxy: AVMediaPlayerProxy?
        private var isRestoring = false

        init(proxy: AVMediaPlayerProxy) {
            self.proxy = proxy
        }

        func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
            isRestoring = false
            Task { @MainActor [weak proxy] in
                proxy?.pictureInPictureChanged(isActive: true, closedByUser: false)
            }
        }

        func pictureInPictureController(
            _ controller: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            isRestoring = true
            completionHandler(true)
        }

        func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
            let closedByUser = !isRestoring
            isRestoring = false
            Task { @MainActor [weak proxy] in
                proxy?.pictureInPictureChanged(isActive: false, closedByUser: closedByUser)
            }
        }
    }
}
#endif

// MARK: - AVPlayerView

extension AVMediaPlayerProxy {

    struct AVPlayerView: PlatformViewRepresentable {

        @EnvironmentObject
        private var proxy: AVMediaPlayerProxy

        func makeUIView(context: Context) -> UIView {
            UIAVPlayerView(proxy: proxy)
        }

        func updateUIView(_ uiView: UIView, context: Context) {}
    }

    private class UIAVPlayerView: UIView {

        let proxy: AVMediaPlayerProxy

        init(proxy: AVMediaPlayerProxy) {
            self.proxy = proxy
            super.init(frame: .zero)
            layer.addSublayer(proxy.avPlayerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            proxy.avPlayerLayer.frame = bounds
        }
    }
}
