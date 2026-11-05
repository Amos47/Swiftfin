//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

// Personal fork: one button for audio and subtitle tracks, replacing the bar and "•••" buttons on iOS.

extension VideoPlayer.PlaybackControls {

    struct AudioSubtitlesButton: View {

        @EnvironmentObject
        private var manager: MediaPlayerManager

        @State
        private var selectedAudioStreamIndex: Int?
        @State
        private var selectedSubtitleStreamIndex: Int?

        var body: some View {
            if let playbackItem = manager.playbackItem {
                Menu {
                    if playbackItem.audioStreams.count > 1 {
                        Section(L10n.audio) {
                            Picker(L10n.audio, selection: $selectedAudioStreamIndex) {
                                ForEach(playbackItem.audioStreams, id: \.index) { stream in
                                    Text(stream.displayTitle ?? L10n.unknown)
                                        .tag(stream.index as Int?)
                                }
                            }
                        }
                    }

                    Section(L10n.subtitles) {
                        Picker(L10n.subtitles, selection: $selectedSubtitleStreamIndex) {
                            ForEach(playbackItem.subtitleStreams.prepending(.none), id: \.index) { stream in
                                Text(stream.displayTitle ?? L10n.unknown)
                                    .tag(stream.index as Int?)
                            }
                        }
                    }
                } label: {
                    Label(L10n.audioAndSubtitles, systemImage: "captions.bubble")
                }
                .tint(.white)
                .foregroundStyle(.white)
                .assign(playbackItem.$selectedAudioStreamIndex, to: $selectedAudioStreamIndex)
                .assign(playbackItem.$selectedSubtitleStreamIndex, to: $selectedSubtitleStreamIndex)
                .onChange(of: selectedAudioStreamIndex) {
                    playbackItem.selectedAudioStreamIndex = selectedAudioStreamIndex
                }
                .onChange(of: selectedSubtitleStreamIndex) {
                    playbackItem.selectedSubtitleStreamIndex = selectedSubtitleStreamIndex
                }
            }
        }
    }
}
