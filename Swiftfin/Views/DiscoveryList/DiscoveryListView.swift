//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import HomeRowsCore
import JellyfinAPI
import Logging
import SwiftUI

// Personal fork: a discovery list's page, laid out like the iPhone series page: a big header (backdrop and title), the
// overview, the list's actions (Watch trailers in the Play spot), then the films as rows. Everything on it comes from
// the server (`Discovery/Lists/{id}/Page` and `/Actions`).

@MainActor
final class DiscoveryListViewModel: ObservableObject {

    @Published
    private(set) var page: DiscoveryListPage?
    @Published
    private(set) var error: Error?
    @Published
    private(set) var actions: [ItemAction] = []

    let listID: String
    private let logger = Logger.swiftfin()

    init(listID: String) {
        self.listID = listID
    }

    /// Loads the page and its actions together. A failed reload keeps the page already on screen.
    func load() async {
        guard let session = Container.shared.currentUserSession() else {
            error = ErrorMessage(L10n.unknownError)
            return
        }

        let api = HomeRowsService.discoveryLists(for: session)
        async let loadedActions = api.actions(listID: listID)
        do {
            page = try await api.page(listID: listID)
            error = nil
        } catch {
            logger.error("Unable to load discovery list \(listID): \(error.localizedDescription)")
            if page == nil {
                self.error = (error as? HomeRowsError) == .status(404)
                    ? ErrorMessage(L10n.discoveryListUnavailable)
                    : error
            }
        }
        actions = await loadedActions
    }
}

struct DiscoveryListView: View {

    // The page's content groups (ContentGroupVStack and the series-page parts) need a focus
    // coordinator in the environment, as ItemView and ContentGroupView provide.
    @StateObject
    private var focusCoordinator = FocusCoordinator()
    @StateObject
    private var viewModel: DiscoveryListViewModel

    private let title: String

    init(listID: String, title: String) {
        self._viewModel = StateObject(wrappedValue: DiscoveryListViewModel(listID: listID))
        self.title = title
    }

    var body: some View {
        ZStack {
            if let page = viewModel.page {
                DiscoveryListContent(page: page, listID: viewModel.listID, actions: viewModel.actions)
            } else if let error = viewModel.error {
                ErrorView(error: error)
            } else {
                ProgressView()
            }
        }
        .animation(.linear(duration: 0.2), value: viewModel.page?.id)
        .environmentObject(focusCoordinator)
        .navigationTitle(viewModel.page?.title ?? title)
        .toolbarTitleDisplayMode(.inline)
        .refreshable {
            await viewModel.load()
        }
        .task {
            guard viewModel.page == nil else { return }
            await viewModel.load()
        }
    }
}

/// The loaded page: series-page scroll view and groups, scrolled to the film the player last closed on.
private struct DiscoveryListContent: View {

    let page: DiscoveryListPage
    let listID: String
    let actions: [ItemAction]

    @ObservedObject
    private var focus = DiscoveryListFocus.shared

    @State
    private var focusedFilmID: String?
    @State
    private var isVisible = false

    private struct HighlightTimer: Equatable {
        let filmID: String?
        let isVisible: Bool
    }

    private var backdropItem: BaseItemDto? {
        page.items.first { $0.id == page.backdropItemID }
    }

    private var groups: [any ContentGroup] {
        let header: any ContentGroup = page.backdropItemID != nil
            ? DiscoveryListHeaderGroup(page: page, backdropItem: backdropItem)
            : SeriesTitleHeaderGroup(item: BaseItemDto(name: page.title))
        return [
            header,
            DiscoveryListOverviewGroup(page: page, listID: listID, actions: actions),
            DiscoveryListFilmsGroup(page: page, listID: listID, focusedFilmID: focusedFilmID),
        ]
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if page.backdropItemID != nil {
                    ItemView.BlurredNavigationBarScrollView(groups: groups)
                } else {
                    ScrollView {
                        ContentGroupVStack(groups: groups)
                            .edgePadding(.bottom)
                    }
                }
            }
            .onAppear {
                isVisible = true
                scrollToFocus(proxy)
            }
            .onDisappear {
                isVisible = false
            }
            .onChange(of: focus.request) {
                scrollToFocus(proxy)
            }
            // The outline goes after a few seconds on screen (not while a film page covers the list).
            .task(id: HighlightTimer(filmID: focusedFilmID, isVisible: isVisible)) {
                guard focusedFilmID != nil, isVisible else { return }
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                withAnimation {
                    focusedFilmID = nil
                }
            }
        }
    }

    /// Scrolls to the film the player closed on, once, when it's on this list, and outlines it for a few seconds.
    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let filmID = focus.take(listID: listID), page.items.contains(where: { $0.id == filmID }) else { return }
        focusedFilmID = filmID
        Task { @MainActor in
            // The page may be under the film page that's being pushed; let the layout settle first.
            try? await Task.sleep(for: .milliseconds(300))
            proxy.scrollTo(filmID, anchor: .center)
        }
    }
}

// MARK: - Header

/// The big header: the list's backdrop with its title over it, in the series header's style.
private struct DiscoveryListHeaderGroup: ContentGroup {

    let id: String = ItemView.Component.header
    let page: DiscoveryListPage
    let backdropItem: BaseItemDto?

    func body(with viewModel: Empty) -> some View {
        DiscoveryListHeader(page: page, backdropItem: backdropItem)
    }
}

private struct DiscoveryListHeader: View {

    let page: DiscoveryListPage
    let backdropItem: BaseItemDto?

    private var backdrop: ImageSource {
        let options = ImageSourceOptions(maxWidth: 1320)
        if let backdropItem {
            return backdropItem.imageSource(.backdrop, environment: options)
        }
        return BaseItemDto().imageSource(itemID: page.backdropItemID, .backdrop, environment: options)
    }

    var body: some View {
        ParallaxBackdropHeader(imageSource: backdrop) {
            AlternateLayoutView(alignment: .bottom) {
                Color.clear
                    .aspectRatio(parallaxBackdropHeaderAspectRatio, contentMode: .fit)
            } content: {
                Text(page.title)
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)
                    .background(
                        alignment: .bottom,
                        extendedBy: .init(vertical: 25, horizontal: EdgeInsets.edgePadding)
                    ) {
                        Rectangle()
                            .fill(Material.ultraThin)
                            .mask(gradient: .eased(.easeOut)) {
                                (location: 0, opacity: 0)
                                (location: 0.2, opacity: 1)
                            }
                    }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Overview and actions

/// The overview, the first play-queue action in the Play spot, then the rest in a series-style action row.
private struct DiscoveryListOverviewGroup: ContentGroup {

    let id = "discovery-list-overview"
    let page: DiscoveryListPage
    let listID: String
    let actions: [ItemAction]

    func body(with viewModel: Empty) -> some View {
        DiscoveryListOverview(page: page, listID: listID, plan: listPageActions(actions: actions))
    }
}

private struct DiscoveryListOverview: View {

    @Router
    private var router

    @StateObject
    private var runner = ItemActionRunner()

    let page: DiscoveryListPage
    let listID: String
    let plan: ListPageActions

    private func run(_ action: ItemActionButton) {
        runner.run(action, listID: listID) { provider, queue in
            router.route(to: .videoPlayer(provider: provider, queue: queue))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SeriesDescription(overview: page.overview)

            if let primary = plan.primary {
                ActionSpotButton(action: primary, isDisabled: runner.isRunning) {
                    run(primary)
                }
                .frame(height: 44)
            }

            if plan.row.isNotEmpty {
                HStack(spacing: 8) {
                    ForEach(plan.row) { action in
                        Button {
                            run(action)
                        } label: {
                            SeriesActionLabel(title: action.label, systemImage: action.systemImage)
                        }
                        .disabled(runner.isRunning)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .edgePadding(.horizontal)
        .errorMessage($runner.error)
        .onDisappear {
            runner.cancel()
        }
    }
}

// MARK: - Films

/// The list's films as series-style rows, in list order. A tap opens the film, which remembers this list.
private struct DiscoveryListFilmsGroup: ContentGroup {

    let id = "discovery-list-films"
    let page: DiscoveryListPage
    let listID: String
    let focusedFilmID: String?

    func body(with viewModel: Empty) -> some View {
        DiscoveryListFilms(films: page.items, listID: listID, focusedFilmID: focusedFilmID)
    }
}

private struct DiscoveryListFilms: View {

    @Router
    private var router

    let films: [BaseItemDto]
    let listID: String
    let focusedFilmID: String?

    /// Films with an id, each tagged by a plain `String` so `scrollTo(filmID)` finds it (an optional tag wouldn't match).
    private var rows: [(id: String, film: BaseItemDto)] {
        films.compactMap { film in film.id.map { ($0, film) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if films.isEmpty {
                Text(L10n.noItems)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }

            ForEach(rows, id: \.id) { row in
                SeriesEpisodeRow(episode: row.film, isCurrent: row.id == focusedFilmID, showsYear: true) {
                    router.route(to: .item(item: row.film, discoveryListID: listID))
                }
                .id(row.id)
            }
        }
        .edgePadding(.horizontal)
        // The rows' menus keep the list when they open the film.
        .environment(\.discoveryListID, listID)
    }
}
