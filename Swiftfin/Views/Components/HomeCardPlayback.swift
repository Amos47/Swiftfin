//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import PlayerCore
import SwiftUI

// Personal fork: what tapping a card does on iPhone, and how a card starts playback.

extension BaseItemDto {

    var cardKind: CardItemKind {
        switch type {
        case .episode: .episode
        case .movie: .movie
        case .series: .series
        default: .other
        }
    }

    /// Plays the item (a series plays next up), or opens its page when there's nothing to play.
    @MainActor
    func play(router: Router.Wrapper, in namespace: Namespace.ID? = nil, fromBeginning: Bool = false) {
        // A series resolves next up over the network first: a second tap meanwhile must not open a second player.
        guard !CardPlayback.isResolving else { return }
        CardPlayback.isResolving = true

        Task { @MainActor in
            defer { CardPlayback.isResolving = false }
            if let playback = try? await ItemPlaybackResolver.playback(for: self, fromBeginning: fromBeginning) {
                router.route(to: .videoPlayer(provider: playback.provider, queue: playback.queue))
            } else if let namespace {
                libraryDidSelectElement(router: router, in: namespace)
            } else {
                router.route(to: .item(item: self))
            }
        }
    }
}

@MainActor
private enum CardPlayback {
    static var isResolving = false
}

/// The "⋯" on a wide Home card: the card's menu, for when tapping the card would play it.
struct CardMoreButton<Item: Poster>: View {

    let item: Item

    var body: some View {
        Menu {
            item.posterContextMenu
                .environment(\.cardTapPlays, true)
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.55), in: Circle())
                .padding(6)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.moreActions)
    }
}
