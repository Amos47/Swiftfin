//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import PlayerCore
import SwiftUI

// Personal fork: shows the hold-to-speed rate; when locked, tapping it returns to the previous speed.

extension VideoPlayer.PlaybackControls {

    struct SpeedPill: View {

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState
        @EnvironmentObject
        private var manager: MediaPlayerManager

        var body: some View {
            if let hold = containerState.speedHold, hold.state == .holding || hold.state == .locked {
                let isLocked = hold.state == .locked

                Button {
                    guard var hold = containerState.speedHold else { return }
                    if let rate = hold.tapPill() {
                        manager.isTemporaryRate = false
                        manager.setRate(rate: rate)
                    }
                    containerState.speedHold = hold
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isLocked ? "lock.fill" : "forward.fill")
                        Text(hold.holdRate, format: .playbackRate)
                        if isLocked {
                            Text(L10n.speedLocked)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(isLocked)
                .transition(.opacity)
            }
        }
    }
}
