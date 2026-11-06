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
        /// Downloads only: Next & delete, or Delete.
        @State
        private var endAction: DownloadEndAction?
        /// A finished download to delete once the next one has started.
        @State
        private var pendingDeletionID: String?

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

            updateEndAction(position: position)
        }

        private func updateEndAction(position: Double) {
            guard manager.playbackItem?.isDownloaded == true, let itemID = manager.item.id else {
                endAction = nil
                return
            }

            // The moment Next Episode would show, whether or not there's a next episode.
            let moment = skipButton(
                position: position,
                runtime: manager.item.runtime?.seconds,
                segments: segments,
                hasNextItem: true,
                isLive: false,
                enteredSegmentAt: enteredSegmentAt
            )
            let isAtMoment = if case .nextEpisode = moment {
                true
            } else {
                false
            }

            let store = Container.shared.downloadStore()
            let episodes = store.episodes(ofSeries: manager.item.seriesID).map {
                DownloadedEpisode(id: $0.id, season: $0.item.parentIndexNumber ?? 0, episode: $0.item.indexNumber ?? 0)
            }

            endAction = downloadEndAction(
                isDownloaded: true,
                atNextEpisodeMoment: isAtMoment,
                nextDownloadedID: nextDownloadedEpisode(after: itemID, in: episodes)
            )
        }

        private func perform(_ action: DownloadEndAction) {
            guard let finishedID = manager.item.id else { return }

            // Deleting keeps this as pending progress until the server has it.
            Container.shared.downloadProgressSync().markWatched(itemID: finishedID)

            switch action {
            case let .nextAndDelete(nextID):
                guard let next = Container.shared.downloadStore().record(for: nextID) else { return }
                pendingDeletionID = finishedID
                manager.playNewItem(provider: next.playerItemProvider)
            case .delete:
                manager.stop()
                Task {
                    // Let the player let go of the file first.
                    try? await Task.sleep(for: .seconds(1))
                    Container.shared.downloadService().cancelOrDelete(itemID: finishedID)
                }
            }
        }

        private func title(for action: DownloadEndAction) -> String {
            switch action {
            case .nextAndDelete: L10n.nextAndDelete
            case .delete: L10n.deleteDownload
            }
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
            HStack(spacing: 10) {
                if let endAction {
                    Button {
                        perform(endAction)
                    } label: {
                        Text(title(for: endAction))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .foregroundStyle(Color.white)
                            .background(Color.white.opacity(0.22), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

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
            .animation(.easeInOut(duration: 0.25), value: endAction)
            .onChange(of: manager.item.id) { _, newID in
                // The next download has started: delete the finished one.
                guard let pendingDeletionID, newID != pendingDeletionID else { return }
                self.pendingDeletionID = nil
                Container.shared.downloadService().cancelOrDelete(itemID: pendingDeletionID)
            }
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
