//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import Get
import HomeRowsCore
import JellyfinAPI
import SwiftUI

final class ItemContentGroupProvider: ViewModel, ContentGroupProvider {

    @Published
    private(set) var item: BaseItemDto
    @Published
    private(set) var localTrailers: [BaseItemDto] = []
    @Published
    private(set) var mediaPlayerItemProvider: MediaPlayerItemProvider?
    @Published
    private(set) var randomBackdropItem: BaseItemDto?
    /// Personal fork: the server's item actions (Watch trailer); nil until the server answers for this item.
    @Published
    private(set) var serverActions: ServerItemActions?
    private var serverActionsTask: Task<Void, Never>?
    /// Personal fork: the Save/Download actions waiting for the server's answer.
    @Published
    private(set) var pendingServerActionIDs: Set<String> = []

    /// Personal fork: the server's answer for this item, or nil while it's still coming.
    var currentServerActions: ServerItemActions? {
        guard let serverActions, serverActions.itemID == item.id else { return nil }
        return serverActions
    }

    /// Personal fork: whether the item can be played. A virtual film (or missing episode) can't; a series counts, since
    /// its Play button plays an episode; a season with no folder is reported Virtual but has a playback provider.
    var isPlayableHere: Bool {
        !item.isMissing || mediaPlayerItemProvider != nil
    }

    /// Personal fork: the Watch trailer action when it takes the Play spot, else nil (the row shows it then).
    var playSpotAction: ItemActionButton? {
        HomeRowsCore.playSpotAction(
            isPlayable: !item.isMissing,
            hasPlaybackProvider: mediaPlayerItemProvider != nil,
            actions: currentServerActions?.actions ?? []
        )
    }

    /// Personal fork: what the big Play spot shows. A virtual film shows Not in your library until the server's
    /// actions arrive, then swaps once to Watch trailer when the server offers it.
    var playSpot: PlaySpot {
        HomeRowsCore.playSpot(isPlayable: isPlayableHere, hasWatchTrailer: playSpotAction != nil)
    }

    let id: String

    /// Personal fork: the season to show first on the iPhone series page (seasons open their series there).
    var preferredSeasonID: String?

    /// Personal fork: the discovery list page this film was opened from, so its Watch trailer continues through that
    /// list.
    var discoveryListID: String?

    var displayTitle: String {
        item.displayTitle
    }

    init(item: BaseItemDto) {
        self.id = item.id ?? "Unknown"
        self.item = item
        super.init()
    }

    init(id: String) {
        self.id = id
        self.item = .init(id: id)
        super.init()
    }

    func makeGroups(environment: Empty) async throws -> [any ContentGroup] {
        let userSession = try requireUserSession()
        loadServerActions(userSession: userSession)
        let fullItem = try await item.getFullItem(userSession: userSession, sendNotification: true)
        // Personal fork: a series' playback resolve (next up, resume, first episode) can fail for a virtual series
        // (discovery, no episodes), and must not fail the whole page: it then has no Play button, only the Play spot.
        let newMediaPlayerItemProvider: MediaPlayerItemProvider? = if fullItem.type == .series {
            try? await resolveMediaPlayerItemProvider(for: fullItem, userSession: userSession)
        } else {
            try await resolveMediaPlayerItemProvider(for: fullItem, userSession: userSession)
        }
        let newLocalTrailers = try? await localTrailers(for: fullItem)
        let newRandomBackdropItem = try? await randomBackdropItem(for: fullItem)

        item = fullItem
        localTrailers = newLocalTrailers ?? []
        mediaPlayerItemProvider = newMediaPlayerItemProvider
        randomBackdropItem = newRandomBackdropItem

        return try await _makeGroups(
            item: fullItem,
            itemID: id
        )
    }

    /// Personal fork: asks the server for the item's actions alongside the page load, without waiting for them, so
    /// the action row is usually complete when it first shows. Every failure is an empty answer.
    private func loadServerActions(userSession: UserSession) {
        serverActionsTask?.cancel()
        guard let itemID = item.id else {
            serverActions = ServerItemActions(itemID: nil, actions: [])
            return
        }

        let api = HomeRowsService.itemActions(for: userSession)
        serverActionsTask = Task { [weak self] in
            let actions = await api.actions(itemID: itemID)
            guard !Task.isCancelled else { return }
            self?.serverActions = ServerItemActions(itemID: itemID, actions: actions)
        }
    }

    /// Personal fork: performs a Save (toggle) or Download (request) action from the action row. A failure rolls a
    /// toggle back and throws, for the row to show.
    func performServerAction(_ button: ItemActionStateButton) async throws {
        guard let itemID = currentServerActions?.itemID,
              !pendingServerActionIDs.contains(button.id),
              let session = userSession
        else { return }

        pendingServerActionIDs.insert(button.id)
        defer { pendingServerActionIDs.remove(button.id) }

        try await ItemActionPerformer.perform(
            actionID: button.id,
            itemID: itemID,
            session: session,
            current: { [weak self] in self?.serverActions?.itemID == itemID ? self?.serverActions?.actions ?? [] : [] },
            pending: { [weak self] in self?.pendingServerActionIDs ?? [] },
            apply: { [weak self] updated in
                guard let self, serverActions?.itemID == itemID else { return }
                serverActions = ServerItemActions(itemID: itemID, actions: updated)
            }
        )
    }

    /// Personal fork: series on iPhone use the new series page (seasons in a drop-down, episodes in one list).
    private func isIOSSeriesPage(_ item: BaseItemDto) -> Bool {
        #if os(iOS)
        item.type == .series
        #else
        false
        #endif
    }

    @ContentGroupBuilder
    private func _makeGroups(item: BaseItemDto, itemID: String) async throws -> [any ContentGroup] {

        if let birthday = item.birthday?.formatted(date: .long, time: .omitted) {
            LabeledContentGroup(
                L10n.born,
                value: birthday
            )
        }

        if let deathday = item.deathday?.formatted(date: .long, time: .omitted) {
            LabeledContentGroup(
                L10n.died,
                value: deathday
            )
        }

        if let birthplace = item.birthplace {
            LabeledContentGroup(
                L10n.birthplace,
                value: birthplace
            )
        }

        #if os(iOS)
        // Personal fork: the iPhone series page: details and actions, then one vertical episode list.
        if item.type == .series {
            SeriesOverviewGroup(provider: self)
            SeriesEpisodeListGroup(
                parent: item,
                playButtonItem: mediaPlayerItemProvider?.item,
                preferredSeasonID: preferredSeasonID
            )
        }
        #endif

        switch item.type {
        case .season, .series:
            if !isIOSSeriesPage(item) {
                SeriesEpisodeContentGroup(
                    parent: item,
                    playButtonItem: mediaPlayerItemProvider?.item
                )
            }
        default:
            []
        }

        if let genres = item.itemGenres, genres.isNotEmpty {
            PillGroup(
                displayTitle: L10n.genres,
                id: "genres",
                elements: genres
            ) { router, element in
                router.route(
                    to: .contentGroup(
                        provider: ItemTypeContentGroupProvider(
                            itemTypes: [
                                BaseItemKind.movie,
                                .series,
                                .boxSet,
                                .episode,
                                .musicVideo,
                                .video,
                                .liveTvProgram,
                                .tvChannel,
                                .person,
                            ],
                            parent: BaseItemDto(name: element.displayTitle),
                            environment: .init(filters: .init(genres: [element]))
                        )
                    )
                )
            }
        }

        if let studios = item.studios, studios.isNotEmpty {
            PillGroup(
                displayTitle: L10n.studios,
                id: "studios",
                elements: studios
            ) { router, element in
                router.route(
                    to: .contentGroup(
                        provider: ItemTypeContentGroupProvider(
                            itemTypes: [
                                BaseItemKind.movie,
                                .series,
                                .boxSet,
                                .episode,
                                .musicVideo,
                                .video,
                                .liveTvProgram,
                                .tvChannel,
                                .person,
                            ],
                            parent: BaseItemDto(id: element.id, name: element.displayTitle, type: .studio)
                        )
                    )
                )
            }
        }

        switch item.type {
        case .movie:
            if item.partCount ?? 0 > 1 {
                PosterGroup(
                    id: "additional-parts",
                    library: AdditionalPartsLibrary(itemID: itemID),
                    posterDisplayType: .landscape,
                    posterSize: .small
                )
            }
        case .boxSet, .person, .musicArtist:
            try await ItemTypeContentGroupProvider(
                itemTypes: BaseItemKind.supportedCases
                    .appending(.episode)
                    .appending(.person),
                parent: item
            )
            .makeGroups(environment: .default)
        case .series:
            if !isIOSSeriesPage(item) {
                try await ItemTypeContentGroupProvider(
                    itemTypes: [.season],
                    parent: item
                )
                .makeGroups(environment: .default)
            }
        case .channel, .liveTvChannel, .tvChannel:
            PosterGroup(
                id: "channel-programs",
                library: ChannelScheduleLibrary(channel: item),
                posterDisplayType: .landscape,
                posterSize: .small
            )
        default: []
        }

        if item.type == .episode {
            PosterGroup(
                library: StaticLibrary(
                    title: L10n.season,
                    id: "seasons",
                    elements: [BaseItemDto(
                        id: item.seasonID,
                        name: item.seasonName,
                        seriesID: item.seriesID,
                        seriesName: item.seriesName,
                        type: .season
                    )]
                ),
                posterSize: .small,
                environment: .init(isHeaderButtonEnabled: false)
            )
        }

        if let castAndCrew = item.people, castAndCrew.isNotEmpty {
            PosterGroup(
                id: "cast-and-crew",
                library: StaticLibrary(
                    title: L10n.castAndCrew.localizedCapitalized,
                    id: "cast-and-crew",
                    elements: castAndCrew
                ),
                posterDisplayType: .portrait,
                posterSize: .small
            )
        }

        #if os(iOS)
        if item.type == .series {
            ExternalLinksGroup(item: item)
        }
        #endif

        PosterGroup(
            id: "special-features",
            library: SpecialFeaturesLibrary(itemID: itemID),
            posterDisplayType: .landscape,
            posterSize: .small
        )

        if Defaults[.Customization.shouldShowRecommendations] {
            PosterGroup(
                id: "similar-items",
                library: SimilarItemsLibrary(itemID: itemID),
                posterDisplayType: .landscape,
                posterSize: .small
            )
        }

        AboutItemGroup(
            displayTitle: L10n.about,
            id: "about",
            item: item
        )
    }

    func toggleIsFavorite() async {
        let beforeIsFavorite = item.userData?.isFavorite ?? false

        item.userData?.isFavorite = !beforeIsFavorite
        do {
            try await setIsFavorite(!beforeIsFavorite)
        } catch {
            item.userData?.isFavorite = beforeIsFavorite
        }
    }

    func toggleIsPlayed() async {
        let beforeIsPlayed = item.userData?.isPlayed ?? false

        item.userData?.isPlayed = !beforeIsPlayed
        do {
            try await setIsPlayed(!beforeIsPlayed)
        } catch {
            item.userData?.isPlayed = beforeIsPlayed
        }
    }

    func selectMediaSource(_ mediaSource: MediaSourceInfo?) {
        guard let mediaPlayerItemProvider, let userSession else { return }

        self.mediaPlayerItemProvider = mediaPlayerItemProvider.item.getPlaybackItemProvider(
            userSession: userSession,
            mediaSource: mediaSource
        )
    }

    // Personal fork: the resolution moved to `ItemPlaybackResolver`, shared with Home cards that play on tap.
    private func resolveMediaPlayerItemProvider(
        for item: BaseItemDto,
        userSession: UserSession
    ) async throws -> MediaPlayerItemProvider? {
        let playbackItem = try await ItemPlaybackResolver.playbackItem(for: item, client: userSession.client)
        return playbackItem?.getPlaybackItemProvider(userSession: userSession)
    }

    private func localTrailers(for item: BaseItemDto) async throws -> [BaseItemDto] {
        guard let itemID = item.id else { return [] }

        let request = try Paths.getLocalTrailers(itemID: itemID, userID: authenticatedUser.id)
        let response = try await send(request)

        return response.value
    }

    private func randomBackdropItem(for item: BaseItemDto) async throws -> BaseItemDto? {
        guard item.type == .person || item.type == .musicArtist || item.type == .boxSet else {
            return nil
        }

        var parameters = Paths.GetItemsParameters()
        parameters.fields = .MinimumFields
        parameters.includeItemTypes = [.movie, .series]
        parameters.isRecursive = true
        parameters.limit = 1
        parameters.sortBy = [.random]
        parameters.userID = try authenticatedUser.id

        switch item.libraryType {
        case .boxSet, .collectionFolder, .userView:
            parameters.parentID = item.id
        case .person:
            parameters.personIDs = item.id.map { [$0] }
        default:
            parameters.parentID = item.id
        }

        let request = Paths.getItems(parameters: parameters)
        let response = try await send(request)

        return response.value.items?.first
    }

    private func setIsPlayed(_ isPlayed: Bool) async throws {
        guard let itemID = item.id else { return }

        let request: Request<UserItemDataDto> = if isPlayed {
            try Paths.markPlayedItem(
                itemID: itemID,
                userID: authenticatedUser.id
            )
        } else {
            try Paths.markUnplayedItem(
                itemID: itemID,
                userID: authenticatedUser.id
            )
        }

        let response = try await send(request)
        Notifications[.itemUserDataDidChange].post(response.value)
        Notifications[.itemShouldRefreshMetadata].post(itemID)
    }

    private func setIsFavorite(_ isFavorite: Bool) async throws {
        guard let itemID = item.id else { return }

        let request: Request<UserItemDataDto> = if isFavorite {
            try Paths.markFavoriteItem(
                itemID: itemID,
                userID: authenticatedUser.id
            )
        } else {
            try Paths.unmarkFavoriteItem(
                itemID: itemID,
                userID: authenticatedUser.id
            )
        }

        let response = try await send(request)
        Notifications[.itemUserDataDidChange].post(response.value)
        Notifications[.itemShouldRefreshMetadata].post(itemID)
    }
}
