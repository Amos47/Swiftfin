//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import JellyfinAPI
import PlayerCore
import SwiftUI

// Personal fork: Skip Intro / Recap / Credits / Preview and Next Episode, from the server's media segments.

extension VideoPlayer.PlaybackControls {

    struct SkipButtonView: View {

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState
        @EnvironmentObject
        private var manager: MediaPlayerManager

        @State
        private var segments: [SkipSegment] = []
        @State
        private var button: SkipButton?
        @State
        private var currentSegmentStart: Double?
        @State
        private var enteredSegmentAt: Double?

        private func title(for button: SkipButton) -> String {
            switch button {
            case .nextEpisode:
                L10n.nextEpisode
            case let .skip(kind, _, _):
                switch kind {
                case .intro: L10n.skipIntro
                case .recap: L10n.skipRecap
                case .outro: L10n.skipCredits
                case .preview: L10n.skipPreview
                }
            }
        }

        private func isProminent(_ button: SkipButton) -> Bool {
            switch button {
            case let .nextEpisode(prominent), let .skip(_, _, prominent):
                prominent
            }
        }

        private func update(position: Double) {
            let containing = segments.filter { $0.start <= position && position < $0.end }.max { $0.start < $1.start }
            if containing?.start != currentSegmentStart {
                currentSegmentStart = containing?.start
                enteredSegmentAt = containing == nil ? nil : position
            }

            button = skipButton(
                position: position,
                runtime: manager.item.runtime?.seconds,
                segments: segments,
                hasNextItem: manager.queue?.nextItem != nil,
                isLive: manager.item.isLiveStream,
                enteredSegmentAt: enteredSegmentAt
            )
        }

        private func perform(_ button: SkipButton) {
            switch button {
            case let .skip(_, to, _):
                let target = Duration.seconds(to)
                manager.seconds = target
                containerState.scrubbedSeconds.value = target
                manager.proxy?.setSeconds(target)
            case .nextEpisode:
                if let nextItem = manager.queue?.nextItem {
                    manager.playNewItem(provider: nextItem)
                }
            }
        }

        private func loadSegments() async {
            segments = []
            guard let itemID = manager.item.id, !manager.item.isLiveStream else { return }

            let mediaSegments: [MediaSegmentDto]
            if manager.playbackItem?.isDownloaded == true, let record = Container.shared.downloadStore().record(for: itemID) {
                // Downloads saved their segments, so the buttons work offline.
                mediaSegments = record.segments
            } else {
                guard let client = Container.shared.currentUserSession()?.client,
                      let result = try? await client.send(Paths.getItemSegments(itemID: itemID)).value
                else { return }
                mediaSegments = result.items ?? []
            }

            segments = mediaSegments.compactMap { segment in
                let kind: SkipKind? = switch segment.type {
                case .intro: .intro
                case .recap: .recap
                case .outro: .outro
                case .preview: .preview
                default: nil
                }
                guard let kind, let start = segment.startTicks, let end = segment.endTicks, end > start else { return nil }
                return SkipSegment(kind: kind, start: Double(start) / 10_000_000, end: Double(end) / 10_000_000)
            }
        }

        var body: some View {
            ZStack {
                if let button {
                    let prominent = isProminent(button)
                    Button {
                        perform(button)
                    } label: {
                        Text(title(for: button))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .foregroundStyle(prominent ? Color.black : Color.white)
                            .background(prominent ? Color.white : Color.white.opacity(0.22), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: button)
            .task(id: manager.item.id) {
                await loadSegments()
                update(position: manager.seconds.seconds)
            }
            .onReceive(manager.secondsBox.$value) { seconds in
                update(position: seconds.seconds)
            }
        }
    }
}
