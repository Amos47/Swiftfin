//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import HomeRowsCore
import JellyfinAPI
import PlayerCore
import SwiftUI

// Personal fork: the iPhone series page's details: year, rating and genres, an expandable description, the play
// button and the action row (overflowing into More), with the server's actions.

struct SeriesOverviewGroup: ContentGroup {

    let id = "series-overview"
    let provider: ItemContentGroupProvider

    func body(with viewModel: Empty) -> Body {
        Body(provider: provider)
    }

    struct Body: View {

        @ObservedObject
        var provider: ItemContentGroupProvider

        private var item: BaseItemDto {
            provider.item
        }

        private var yearsText: String? {
            guard let start = item.productionYear else { return nil }
            let end = item.endDate.map { Calendar.current.component(.year, from: $0) }

            if let end, end != start {
                return "\(start)–\(end)"
            }
            if item.status == "Continuing" {
                return "\(start)–"
            }
            return "\(start)"
        }

        private var genresText: String? {
            guard let genres = item.genres, genres.isNotEmpty else { return nil }
            return genres.prefix(2).joined(separator: " · ")
        }

        private var metadataLine: some View {
            HStack(spacing: 8) {
                if let yearsText {
                    Text(verbatim: yearsText)
                }

                if let rating = item.communityRating {
                    Label {
                        Text(rating, format: .number.precision(.fractionLength(1)))
                    } icon: {
                        Image(systemName: "star.fill")
                    }
                    .labelStyle(.titleAndIcon)
                }

                if let officialRating = item.officialRating {
                    Text(verbatim: officialRating)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary, lineWidth: 1))
                }

                if let genresText {
                    Text(verbatim: genresText)
                        .lineLimit(1)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                metadataLine

                SeriesDescription(overview: item.overview)

                if item.presentPlayButton {
                    PlayButton(provider: provider)
                }

                SeriesActionRow(provider: provider)
            }
            .edgePadding(.horizontal)
        }
    }
}

/// Watched, Favourite, the server's actions (Watch trailer when it isn't in the Play spot, Save, Download), Trailers and
/// Edit, in that order (`seriesActionRow`). Up to `maxVisibleActions` show; with more, the last slot becomes More holding
/// the rest. A virtual series (discovery) has no Watched or Favourite.
struct SeriesActionRow: View {

    @ObservedObject
    var provider: ItemContentGroupProvider

    @Router
    private var router

    @StoredValue(.User.enabledTrailers)
    private var enabledTrailers: TrailerSelection

    // Personal fork: runs the server's play-queue actions, the same way the film page's row does.
    @StateObject
    private var actionRunner = ItemActionRunner()

    private var item: BaseItemDto {
        provider.item
    }

    private var hasTrailers: Bool {
        (enabledTrailers.contains(.local) && provider.localTrailers.isNotEmpty)
            || (enabledTrailers.contains(.external) && item.remoteTrailers?.isNotEmpty == true)
    }

    private var actions: [SeriesRowAction] {
        seriesActionRow(
            isMissing: item.isMissing,
            canBePlayed: item.canBePlayed,
            canBeFavorited: item.canBeFavorited,
            hasStockTrailers: hasTrailers,
            canEdit: item.canEdit,
            serverActions: provider.currentServerActions?.actions,
            watchTrailerInPlaySpot: provider.playSpotAction != nil
        )
    }

    private func label(_ title: String, systemImage: String, isOn: Bool = false, tint: Color = .primary) -> some View {
        SeriesActionLabel(title: title, systemImage: systemImage, isOn: isOn, tint: tint)
    }

    @ViewBuilder
    private func button(for action: SeriesRowAction) -> some View {
        switch action {
        case .watched:
            let isPlayed = item.userData?.isPlayed == true
            Button {
                Task { await provider.toggleIsPlayed() }
            } label: {
                label(
                    L10n.played,
                    systemImage: isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                    isOn: isPlayed,
                    tint: .jellyfinPurple
                )
            }
        case .favourite:
            let isFavourite = item.userData?.isFavorite == true
            Button {
                Task { await provider.toggleIsFavorite() }
            } label: {
                label(L10n.favorited, systemImage: isFavourite ? "heart.fill" : "heart", isOn: isFavourite, tint: .pink)
            }
        case let .server(serverAction):
            Button {
                play(serverAction)
            } label: {
                label(serverAction.label, systemImage: serverAction.systemImage)
            }
            .disabled(actionRunner.isRunning)
        case let .state(stateButton):
            Button {
                perform(stateButton)
            } label: {
                label(stateButton.label, systemImage: stateButton.systemImage, isOn: stateButton.isOn, tint: .jellyfinPurple)
            }
            .disabled(!stateButton.isEnabled || provider.pendingServerActionIDs.contains(stateButton.id))
            .accessibilityLabel(stateButton.label)
        case .trailers:
            ItemView.TrailerMenu(localTrailers: provider.localTrailers, externalTrailers: item.remoteTrailers ?? []) {
                label(L10n.trailers, systemImage: "movieclapper")
            }
        case .edit:
            ItemView.EditItemMenu(item: item) {
                label(L10n.edit, systemImage: "pencil")
            }
        }
    }

    /// Plays a server action's queue (Watch trailer), as the film page's row does.
    private func play(_ action: ItemActionButton) {
        actionRunner.run(action, item: item, listID: provider.discoveryListID) { provider, queue in
            router.route(to: .videoPlayer(provider: provider, queue: queue))
        }
    }

    /// Performs Save or Download through the provider (the film page's path); a failure shows the row's error.
    private func perform(_ button: ItemActionStateButton) {
        Task {
            do {
                try await provider.performServerAction(button)
            } catch {
                actionRunner.error = ErrorMessage(L10n.unknownError)
            }
        }
    }

    var body: some View {
        let actions = actions
        let split = splitActions(actions)

        if actions.isNotEmpty {
            HStack(spacing: 8) {
                ForEach(split.visible) { action in
                    button(for: action)
                }

                if split.overflow.isNotEmpty {
                    Menu {
                        ForEach(split.overflow) { action in
                            button(for: action)
                        }
                    } label: {
                        label(L10n.more, systemImage: "ellipsis")
                    }
                }
            }
            .buttonStyle(.plain)
            .errorMessage($actionRunner.error)
            .onDisappear {
                actionRunner.cancel()
            }
        }
    }
}

/// A series-page description: two lines with See more, tapping expands it. Nothing without an overview.
struct SeriesDescription: View {

    let overview: String?

    @State
    private var isExpanded = false

    var body: some View {
        if let overview, overview.isNotEmpty {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(overview)
                        .lineLimit(isExpanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !isExpanded {
                        Text(L10n.seeMore)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
            .buttonStyle(.plain)
        }
    }
}

/// One button's look in a series-page action row: an icon over a small caption.
struct SeriesActionLabel: View {

    let title: String
    let systemImage: String
    var isOn: Bool = false
    var tint: Color = .primary

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(isOn ? tint : .primary)
                .frame(height: 26)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
