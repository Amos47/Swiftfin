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
    let preferredSeasonID: String?
    let viewModel: PagingLibraryViewModel<SeasonViewModelLibrary>

    var _shouldBeResolved: Bool {
        viewModel.elements.isNotEmpty
    }

    init(parent: BaseItemDto, playButtonItem: BaseItemDto? = nil, preferredSeasonID: String? = nil) {
        self.id = "\(parent.id ?? "parent")-episode-list"
        self.playButtonItem = playButtonItem
        self.preferredSeasonID = preferredSeasonID
        self.viewModel = .init(library: SeasonViewModelLibrary(parent: parent), pageSize: 100)
    }

    func body(with viewModel: PagingLibraryViewModel<SeasonViewModelLibrary>) -> Body {
        Body(viewModel: viewModel, playButtonItem: playButtonItem, preferredSeasonID: preferredSeasonID)
    }

    struct Body: View {

        @ObservedObject
        var viewModel: PagingLibraryViewModel<SeasonViewModelLibrary>

        let playButtonItem: BaseItemDto?
        let preferredSeasonID: String?

        @State
        private var selection: PagingLibraryViewModel<EpisodeLibrary>.ID?
        /// The page scrolls to the current episode once, when it opens; switching seasons doesn't scroll.
        @State
        private var didAutoScroll = false
        /// How far down the group the pinned season bar sits; nil when the season picker is on screen.
        @State
        private var pinnedBarOffset: CGFloat?
        @Environment(\.scrollItemPageToTop)
        private var scrollItemPageToTop
        @Environment(\.scrollItemPage)
        private var scrollItemPage

        /// The top edge the pinned bar sticks to: under the status bar and the navigation bar.
        private var pinnedTop: CGFloat {
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first
            return (window?.safeAreaInsets.top ?? 47) + 44
        }

        private func jumpButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }

        /// The episode to jump back to: the one in progress or up next, else the current one in this season.
        private var myEpisode: (seasonID: String?, episodeID: String)? {
            if let item = playButtonItem, let id = item.id, item.type == .episode {
                return (item.seasonID, id)
            }
            guard let selectedSeason else { return nil }
            let progress = selectedSeason.elements.map {
                EpisodeProgress(
                    id: $0.id ?? "",
                    isPlayed: $0.userData?.isPlayed == true,
                    progress: ($0.userData?.playedPercentage ?? 0) / 100
                )
            }
            return currentEpisodeID(in: progress, preferredID: nil).map { (selection, $0) }
        }

        private func jumpToMyEpisode() {
            guard let myEpisode else { return }

            if let seasonID = myEpisode.seasonID, seasonID != selection,
               viewModel.elements.contains(where: { $0.id == seasonID })
            {
                // Switch season first; its rows need a moment to load before they can be scrolled to.
                selection = seasonID
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    scrollItemPage?(myEpisode.episodeID, .center)
                }
            } else {
                scrollItemPage?(myEpisode.episodeID, .center)
            }
        }

        /// Top of the page, my episode, end of the season.
        private var jumpButtons: some View {
            HStack(spacing: 8) {
                jumpButton("arrow.up.to.line", label: L10n.scrollToTop) {
                    scrollItemPageToTop?()
                }

                if myEpisode != nil {
                    jumpButton("play.circle", label: L10n.jumpToMyEpisode) {
                        jumpToMyEpisode()
                    }
                }

                jumpButton("arrow.down.to.line", label: L10n.scrollToBottom) {
                    if let lastID = selectedSeason?.elements.last?.id {
                        scrollItemPage?(lastID, .bottom)
                    }
                }
            }
            .edgePadding(.trailing)
        }

        private var seasonHeader: some View {
            HStack {
                SeriesEpisodeContentGroup.SeasonSelector(
                    seasons: Array(viewModel.elements),
                    selection: $selection,
                    preferredSelection: selection ?? preferredSeason()
                )

                Spacer()

                jumpButtons
            }
        }

        private var pinnedBar: some View {
            seasonHeader
                .padding(.vertical, 8)
                // Solid, and reaching up behind the navigation bar so nothing shows through above it.
                .background(alignment: .bottom) {
                    Color(uiColor: .systemBackground)
                        .padding(.top, -pinnedTop)
                }
        }

        private var selectedSeason: PagingLibraryViewModel<EpisodeLibrary>? {
            viewModel.elements.first { $0.id == selection }
        }

        private func preferredSeason() -> PagingLibraryViewModel<EpisodeLibrary>.ID? {
            // A season card opened this page: show that season.
            if let preferredSeasonID, viewModel.elements.contains(where: { $0.id == preferredSeasonID }) {
                return preferredSeasonID
            }
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
            content
                // Personal fork: once the season picker scrolls under the navigation bar, a copy pins to the top with a
                // button back to the top of the page.
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .onChange(of: geometry.frame(in: .global).minY, initial: true) { _, minY in
                                    let scrolledPast = pinnedTop - minY
                                    pinnedBarOffset = scrolledPast > 0
                                        ? min(scrolledPast, max(0, geometry.size.height - 60))
                                        : nil
                                }
                        }
                    }
                    .overlay(alignment: .top) {
                        if let pinnedBarOffset {
                            pinnedBar
                                .offset(y: pinnedBarOffset)
                        }
                    }
        }

        private var content: some View {
            VStack(alignment: .leading, spacing: 12) {
                seasonHeader

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

    @Environment(\.scrollItemPage)
    private var scrollItemPage

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
            scrollToCurrent()
        }
        .onAppear {
            scrollToCurrent()
        }
    }

    /// Brings the current episode into view once, unless it's the first in the list (the page is already there).
    private func scrollToCurrent() {
        guard !didAutoScroll, let currentID, episodes.contains(where: { $0.id == currentID }) else { return }

        didAutoScroll = true
        guard episodes.first?.id != currentID else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            scrollItemPage?(currentID, .center)
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
        let base = episode.progressLabel ?? episode.runTimeLabel

        // Personal fork: when it was last watched, to find a rewatch on the series page.
        guard let lastPlayed = lastPlayedDateText(
            isPlayed: episode.userData?.isPlayed == true,
            lastPlayed: episode.userData?.lastPlayedDate
        ) else { return base }

        return [base, L10n.lastPlayedDate(lastPlayed)].compactMap(\.self).joined(separator: " · ")
    }

    private var thumbnail: some View {
        ImageView(episode.landscapeImageSources(environment: .init(maxWidth: 250)))
            .failure {
                SystemImageContentView(systemName: episode.systemImage)
            }
            .aspectRatio(16 / 9, contentMode: .fill)
            .frame(width: 116)
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

            // Personal fork: download and "⋯" side by side.
            HStack(spacing: 0) {
                if !episode.isMissing {
                    DownloadButton(item: episode)
                }

                Menu {
                    episode.posterContextMenu
                        .environment(\.cardTapPlays, true)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.moreActions)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(6)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.jellyfinPurple, lineWidth: 1.5)
                .opacity(isCurrent ? 1 : 0)
        }
    }
}
