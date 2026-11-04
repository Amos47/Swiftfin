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
    }

    private func playNew(item: MediaPlayerItem) {
        removeItemObservers()

        let baseItem = item.baseItem
        let newAVPlayerItem = AVPlayerItem(url: item.url)
        newAVPlayerItem.externalMetadata = item.baseItem.avMetadata

        hasFirstFrame = false
        didStartCurrentItem = false
        player.replaceCurrentItem(with: newAVPlayerItem)

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
                    if let error = self.player.error ?? avItem.error {
                        self.manager?.error(ErrorMessage("AVPlayer error: \(error.localizedDescription)"))
                    }
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
