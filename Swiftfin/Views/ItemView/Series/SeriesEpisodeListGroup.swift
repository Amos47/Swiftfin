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

// Personal fork: the iPhone series page's episodes: a season drop-down and one vertical list, opening scrolled to the
// episode in progress or up next.

struct SeriesEpisodeListGroup: ContentGroup, Identifiable {

    let id: String
    let playButtonItem: BaseItemDto?
    let viewModel: PagingLibraryViewModel<SeasonViewModelLibrary>

    var _shouldBeResolved: Bool {
        viewModel.elements.isNotEmpty
    }

    init(parent: BaseItemDto, playButtonItem: BaseItemDto? = nil) {
        self.id = "\(parent.id ?? "parent")-episode-list"
        self.playButtonItem = playButtonItem
        self.viewModel = .init(library: SeasonViewModelLibrary(parent: parent), pageSize: 100)
    }

    func body(with viewModel: PagingLibraryViewModel<SeasonViewModelLibrary>) -> Body {
        Body(viewModel: viewModel, playButtonItem: playButtonItem)
    }

    struct Body: View {

        @ObservedObject
        var viewModel: PagingLibraryViewModel<SeasonViewModelLibrary>

        let playButtonItem: BaseItemDto?

        @State
        private var selection: PagingLibraryViewModel<EpisodeLibrary>.ID?
        /// The page scrolls to the current episode once, when it opens; switching seasons doesn't scroll.
        @State
        private var didAutoScroll = false

        private var selectedSeason: PagingLibraryViewModel<EpisodeLibrary>? {
            viewModel.elements.first { $0.id == selection }
        }

        private func preferredSeason() -> PagingLibraryViewModel<EpisodeLibrary>.ID? {
            if let seasonID = playButtonItem?.seasonID, viewModel.elements.contains(where: { $0.id == seasonID }) {
                return seasonID
            }
            return viewModel.elements.first?.id
        }

        private func selectPreferredSeasonIfNeeded() {
            if selection == nil || !viewModel.elements.contains(where: { $0.id == selection }) {
                selection = preferredSeason()
            }
        }

        private func loadSelectedSeasonIfNeeded() {
            guard let selectedSeason, selectedSeason.state == .initial else { return }
            selectedSeason.refresh()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                SeriesEpisodeContentGroup.SeasonSelector(
                    seasons: Array(viewModel.elements),
                    selection: $selection,
                    preferredSelection: selection ?? preferredSeason()
                )

                if let selectedSeason {
                    SeasonEpisodeRows(season: selectedSeason, preferredID: playButtonItem?.id, didAutoScroll: $didAutoScroll)
                        .id(ObjectIdentifier(selectedSeason))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .onFirstAppear {
                selectPreferredSeasonIfNeeded()
                loadSelectedSeasonIfNeeded()
            }
            .onChange(of: viewModel.elements.count) {
                selectPreferredSeasonIfNeeded()
            }
            .onChange(of: selection) {
                loadSelectedSeasonIfNeeded()
            }
        }
    }
}

private struct SeasonEpisodeRows: View {

    @ObservedObject
    var season: PagingLibraryViewModel<EpisodeLibrary>

    let preferredID: String?

    @Binding
    var didAutoScroll: Bool

    private var episodes: [BaseItemDto] {
        Array(season.elements)
    }

    private var currentID: String? {
        currentEpisodeID(
            in: episodes.map {
                EpisodeProgress(
                    id: $0.id ?? "",
                    isPlayed: $0.userData?.isPlayed == true,
                    progress: ($0.userData?.playedPercentage ?? 0) / 100
                )
            },
            preferredID: preferredID
        )
    }

    var body: some View {
        let currentID = currentID

        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                if episodes.isEmpty {
                    switch season.state {
                    case .error:
                        VStack(spacing: 8) {
                            Text(season.error?.localizedDescription ?? L10n.unknownError)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button(L10n.retry) {
                                season.refresh()
                            }
                            .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity)
                    default:
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                }

                ForEach(episodes, id: \.id) { episode in
                    SeriesEpisodeRow(episode: episode, isCurrent: episode.id == currentID)
                        .id(episode.id)
                }
            }
            .edgePadding(.horizontal)
            .task(id: ObjectIdentifier(season)) {
                // A refreshed page hands over new, unloaded seasons: load the one on screen.
                if season.state == .initial {
                    season.refresh()
                }
            }
            .onChange(of: episodes.count) {
                scrollToCurrent(proxy)
            }
            .onAppear {
                scrollToCurrent(proxy)
            }
        }
    }

    /// Brings the current episode into view once, unless it's the first in the list (the page is already there).
    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard !didAutoScroll, let currentID, episodes.contains(where: { $0.id == currentID }) else { return }

        didAutoScroll = true
        guard episodes.first?.id != currentID else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(.easeInOut) {
                proxy.scrollTo(currentID, anchor: .center)
            }
        }
    }
}

struct SeriesEpisodeRow: View {

    @Router
    private var router

    let episode: BaseItemDto
    let isCurrent: Bool

    private var title: String {
        if let number = episode.indexNumber {
            return "\(number) · \(episode.displayTitle)"
        }
        return episode.displayTitle
    }

    private var detail: String? {
        episode.progressLabel ?? episode.runTimeLabel
    }

    private var thumbnail: some View {
        ImageView(episode.landscapeImageSources(environment: .init(maxWidth: 250)))
            .failure {
                SystemImageContentView(systemName: episode.systemImage)
            }
            .aspectRatio(16 / 9, contentMode: .fill)
            .frame(width: 140)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) {
                if let percentage = episode.userData?.playedPercentage, percentage > 0, episode.userData?.isPlayed != true {
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(Color.jellyfinPurple)
                            .frame(width: geometry.size.width * percentage / 100, height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if episode.userData?.isPlayed == true {
                    PlayedIndicator()
                        .frame(width: 20, height: 20)
                        .padding(4)
                }
            }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                episode.play(router: router)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    thumbnail

                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if let overview = episode.overview, overview.isNotEmpty {
                            Text(overview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }

                        if let detail {
                            Text(verbatim: detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                episode.posterContextMenu
                    .environment(\.cardTapPlays, true)
            }

            Menu {
                episode.posterContextMenu
                    .environment(\.cardTapPlays, true)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.moreActions)
        }
        .padding(6)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.jellyfinPurple, lineWidth: 1.5)
                .opacity(isCurrent ? 1 : 0)
        }
    }
}
