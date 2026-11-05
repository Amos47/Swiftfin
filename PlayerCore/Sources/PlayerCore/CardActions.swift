//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

/// Rules for cards and the series page: what a tap does, the card menu, the action row and the current episode.

public enum CardItemKind: Sendable {
    case episode
    case movie
    case series
    /// Seasons, box sets, folders, music, people, live TV and the rest: these open their page.
    case other
}

public enum CardTap: Sendable, Equatable {
    case play
    case open
}

/// Wide episode and movie cards play, wherever they appear; everything else, wide shows included, opens its page.
public func cardTap(kind: CardItemKind, isWide: Bool) -> CardTap {
    guard isWide, kind == .episode || kind == .movie else { return .open }
    return .play
}

public enum CardMenuItem: Sendable, Equatable {
    case play
    case playFromBeginning
    case goToItem
    case goToShow
    /// `true` marks it watched, `false` marks it unwatched.
    case markWatched(Bool)
    /// `true` adds it to favourites, `false` removes it.
    case favourite(Bool)
}

/// The card menu, in order. Play is left out where tapping the card already plays.
///
/// - Parameter canMarkWatched: whether the item can be marked watched (seasons, box sets and folders can, though they
///   don't play from a card); nil means only episodes, movies and series.
public func cardMenuItems(
    kind: CardItemKind,
    tapPlays: Bool,
    hasProgress: Bool,
    isPlayed: Bool,
    isFavourite: Bool,
    canMarkWatched: Bool? = nil
) -> [CardMenuItem] {
    var items: [CardMenuItem] = []
    let isPlayable = kind != .other

    if isPlayable, !tapPlays {
        items.append(.play)
    }
    if hasProgress, kind == .episode || kind == .movie {
        items.append(.playFromBeginning)
    }

    items.append(.goToItem)

    if kind == .episode {
        items.append(.goToShow)
    }
    if canMarkWatched ?? isPlayable {
        items.append(.markWatched(!isPlayed))
    }

    items.append(.favourite(!isFavourite))
    return items
}

/// How many action buttons fit in the series page's row.
public let maxVisibleActions = 4

/// Actions that fit show in the row; with more than fit, the last slot becomes "More" holding the rest.
public func splitActions<T>(_ actions: [T], maxVisible: Int = maxVisibleActions) -> (visible: [T], overflow: [T]) {
    guard actions.count > maxVisible else { return (actions, []) }
    let shown = max(0, maxVisible - 1)
    return (Array(actions.prefix(shown)), Array(actions.dropFirst(shown)))
}

public struct EpisodeProgress: Sendable {

    public let id: String
    public let isPlayed: Bool
    /// 0…1
    public let progress: Double

    public init(id: String, isPlayed: Bool, progress: Double) {
        self.id = id
        self.isPlayed = isPlayed
        self.progress = progress
    }
}

/// The episode to outline and scroll to: the preferred one (next up / resume) if it's in this season, else the one in
/// progress, else the first unwatched one.
public func currentEpisodeID(in episodes: [EpisodeProgress], preferredID: String?) -> String? {
    if let preferredID, episodes.contains(where: { $0.id == preferredID }) {
        return preferredID
    }
    if let inProgress = episodes.first(where: { !$0.isPlayed && $0.progress > 0 }) {
        return inProgress.id
    }
    return episodes.first(where: { !$0.isPlayed })?.id
}
