//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import HomeRowsCore
import SwiftUI

// Personal fork: the server's Save and Download actions for the item that's playing, in the top bar beside Audio &
// Subtitles. A trailer's actions are its film's. More than 2 go into one overflow menu; a stock server shows nothing.

extension VideoPlayer.PlaybackControls {

    struct ServerActionButtons: View {

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState
        @EnvironmentObject
        private var manager: MediaPlayerManager

        /// Owned by the top bar, which loads it for each item, so this view adds nothing to the bar while it's empty.
        @ObservedObject
        var model: PlayerServerActions

        private var layout: (inline: [ItemActionStateButton], overflow: [ItemActionStateButton]) {
            playerActionLayout(actions: model.actions(for: manager.item.id))
        }

        var body: some View {
            let layout = layout

            // A Group, so the buttons join the bar's own row (no gap on a stock server).
            Group {
                ForEach(layout.inline) { button in
                    Button {
                        perform(button)
                    } label: {
                        Label(button.label, systemImage: button.systemImage)
                    }
                    .disabled(isDisabled(button))
                    .frame(width: VideoPlayer.PlaybackControls.Toolbar.buttonSize, height: VideoPlayer.PlaybackControls.Toolbar.buttonSize)
                }

                if layout.overflow.isNotEmpty {
                    Menu {
                        ForEach(layout.overflow) { button in
                            Button(button.label, systemImage: button.systemImage) {
                                perform(button)
                            }
                            .disabled(isDisabled(button))
                        }
                    } label: {
                        Label(L10n.moreActions, systemImage: "ellipsis.circle")
                    }
                    .frame(width: VideoPlayer.PlaybackControls.Toolbar.buttonSize, height: VideoPlayer.PlaybackControls.Toolbar.buttonSize)
                }
            }
            .tint(.white)
            .foregroundStyle(.white)
        }

        private func isDisabled(_ button: ItemActionStateButton) -> Bool {
            !button.isEnabled || model.pendingIDs.contains(button.id)
        }

        private func perform(_ button: ItemActionStateButton) {
            containerState.timer.poke()
            model.perform(button)
        }
    }
}
