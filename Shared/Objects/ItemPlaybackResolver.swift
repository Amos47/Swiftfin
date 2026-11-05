//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import Foundation
import JellyfinAPI

// Personal fork: what to play for an item. Shared by the item page's play button and Home cards that play on tap.

enum ItemPlaybackResolver {

    /// The playable item for `item`: a series plays next up, else what's in progress, else its first episode; a season
    /// plays what's in progress, else its first episode; other playable items play themselves.
    static func playbackItem(for item: BaseItemDto, client: JellyfinClient) async throws -> BaseItemDto? {
        switch item.type {
        case .series:
            if let nextUp = try await nextUpItem(for: item, client: client) {
                nextUp
            } else if let resumeItem = try await resumeItem(for: item, client: client) {
                resumeItem
            } else {
                try await firstAvailableItem(for: item, client: client)
            }
        case .season:
            if let resumeItem = try await resumeItem(for: item, client: client) {
                resumeItem
            } else {
                try await firstAvailableItem(for: item, client: client)
            }
        default:
            item.isPlayable ? item : nil
        }
    }

    /// The player's provider and queue for `item`, or nil when there's nothing to play. Episodes get their series queue
    /// so Next Episode and autoplay work.
    @MainActor
    static func playback(
        for item: BaseItemDto,
        fromBeginning: Bool = false
    ) async throws -> (provider: MediaPlayerItemProvider, queue: (any MediaPlayerQueue)?)? {
        guard let userSession = Container.shared.currentUserSession(),
              let playbackItem = try await playbackItem(for: item, client: userSession.client),
              var provider = playbackItem.getPlaybackItemProvider(userSession: userSession)
        else { return nil }

        if fromBeginning {
            provider = provider.modifyingItem { $0.userData?.playbackPositionTicks = 0 }
        }

        let queue: (any MediaPlayerQueue)? = playbackItem.type == .episode ? EpisodeMediaPlayerQueue(episode: playbackItem) : nil
        return (provider, queue)
    }

    private static func nextUpItem(for item: BaseItemDto, client: JellyfinClient) async throws -> BaseItemDto? {
        var parameters = Paths.GetNextUpParameters()
        parameters.fields = .MinimumFields
        parameters.seriesID = item.id

        let response = try await client.send(Paths.getNextUp(parameters: parameters))

        guard let item = response.value.items?.first, !item.isMissing else {
            return nil
        }

        return item
    }

    private static func resumeItem(for item: BaseItemDto, client: JellyfinClient) async throws -> BaseItemDto? {
        var parameters = Paths.GetResumeItemsParameters()
        parameters.fields = .MinimumFields
        parameters.limit = 1
        parameters.parentID = item.id

        let response = try await client.send(Paths.getResumeItems(parameters: parameters))
        return response.value.items?.first
    }

    private static func firstAvailableItem(for item: BaseItemDto, client: JellyfinClient) async throws -> BaseItemDto? {
        var parameters = Paths.GetItemsParameters()
        parameters.fields = .MinimumFields
        parameters.includeItemTypes = [.episode]
        parameters.isMissing = false
        parameters.isRecursive = true
        parameters.limit = 1
        parameters.parentID = item.id
        parameters.sortOrder = [.ascending]

        let response = try await client.send(Paths.getItems(parameters: parameters))
        return response.value.items?.first
    }
}
