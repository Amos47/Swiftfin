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

// Personal fork: the iPhone series page's details: year, rating and genres, an expandable description, the play
// button and the action row (overflowing into More).

struct SeriesOverviewGroup: ContentGroup {

    let id = "series-overview"
    let provider: ItemContentGroupProvider

    func body(with viewModel: Empty) -> Body {
        Body(provider: provider)
    }

    struct Body: View {

        @ObservedObject
        var provider: ItemContentGroupProvider

        @State
        private var isDescriptionExpanded = false

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

        @ViewBuilder
        private var description: some View {
            if let overview = item.overview, overview.isNotEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isDescriptionExpanded.toggle()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(overview)
                            .lineLimit(isDescriptionExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !isDescriptionExpanded {
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

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                metadataLine

                description

                if item.presentPlayButton {
                    PlayButton(provider: provider)
                }

                SeriesActionRow(provider: provider)
            }
            .edgePadding(.horizontal)
        }
    }
}

/// Watched, Favourite, Trailer and Edit, in that order. Up to `maxVisibleActions` show; with more, the last slot becomes
/// More holding the rest.
struct SeriesActionRow: View {

    enum Action: Hashable {
        case watched
        case favourite
        case trailer
        case edit
    }

    @ObservedObject
    var provider: ItemContentGroupProvider

    @StoredValue(.User.enabledTrailers)
    private var enabledTrailers: TrailerSelection

    private var item: BaseItemDto {
        provider.item
    }

    private var hasTrailers: Bool {
        (enabledTrailers.contains(.local) && provider.localTrailers.isNotEmpty)
            || (enabledTrailers.contains(.external) && item.remoteTrailers?.isNotEmpty == true)
    }

    private var actions: [Action] {
        var actions: [Action] = []
        if item.canBePlayed {
            actions.append(.watched)
        }
        if item.canBeFavorited {
            actions.append(.favourite)
        }
        if hasTrailers {
            actions.append(.trailer)
        }
        if item.canEdit {
            actions.append(.edit)
        }
        return actions
    }

    private func label(_ title: String, systemImage: String, isOn: Bool = false, tint: Color = .primary) -> some View {
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

    @ViewBuilder
    private func button(for action: Action) -> some View {
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
        case .trailer:
            ItemView.TrailerMenu(localTrailers: provider.localTrailers, externalTrailers: item.remoteTrailers ?? []) {
                label(L10n.trailers, systemImage: "movieclapper")
            }
        case .edit:
            ItemView.EditItemMenu(item: item) {
                label(L10n.edit, systemImage: "pencil")
            }
        }
    }

    var body: some View {
        let split = splitActions(actions)

        if actions.isNotEmpty {
            HStack(spacing: 8) {
                ForEach(split.visible, id: \.self) { action in
                    button(for: action)
                }

                if split.overflow.isNotEmpty {
                    Menu {
                        ForEach(split.overflow, id: \.self) { action in
                            button(for: action)
                        }
                    } label: {
                        label(L10n.more, systemImage: "ellipsis")
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}
