//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// Personal fork: which items a player queue's Previous and Next may point at (iOS and tvOS, so it lives here and not in
// PlayerCore, which is iOS-only).

/// What the player knows about one queue item.
public struct QueueCandidate: Equatable, Sendable {

    public let id: String
    /// A missing (virtual) item: listed by the server but with no file.
    public let isMissing: Bool
    public let isUnaired: Bool
    /// Whether the item has media sources; nil when they weren't fetched.
    public let hasMedia: Bool?

    public init(id: String, isMissing: Bool, isUnaired: Bool, hasMedia: Bool?) {
        self.id = id
        self.isMissing = isMissing
        self.isUnaired = isUnaired
        self.hasMedia = hasMedia
    }
}

/// An item Previous or Next may play: not missing, aired, and not known to have no media.
public func isValidQueueTarget(_ candidate: QueueCandidate) -> Bool {
    !candidate.isMissing && !candidate.isUnaired && candidate.hasMedia != false
}

/// The indices of the nearest valid targets before and after the current item.
public struct QueueNeighbours: Equatable, Sendable {

    public let previous: Int?
    public let next: Int?

    public var hasPrevious: Bool {
        previous != nil
    }

    public var hasNext: Bool {
        next != nil
    }
}

/// The nearest valid targets on either side of `currentID` in `candidates`, skipping invalid ones. An id that isn't in
/// the list (or none) has neither.
public func playableNeighbours(of currentID: String?, in candidates: [QueueCandidate]) -> QueueNeighbours {
    guard let currentID, let index = candidates.firstIndex(where: { $0.id == currentID }) else {
        return QueueNeighbours(previous: nil, next: nil)
    }
    let previous = candidates[..<index].lastIndex(where: isValidQueueTarget)
    let next = candidates[(index + 1)...].firstIndex(where: isValidQueueTarget)
    return QueueNeighbours(previous: previous, next: next)
}

/// A fixed play list: the fetched items in the order of `ids`, leaving out ids the fetch didn't return (deleted items),
/// items that aren't valid targets, and repeats of an id. `candidate` returns nil for an item with no id.
public func playableQueue<Item>(ids: [String], fetched: [Item], candidate: (Item) -> QueueCandidate?) -> [Item] {
    var byID: [String: (item: Item, candidate: QueueCandidate)] = [:]
    for item in fetched {
        if let candidate = candidate(item), byID[candidate.id] == nil {
            byID[candidate.id] = (item, candidate)
        }
    }
    var seen: Set<String> = []
    return ids.compactMap { id in
        guard seen.insert(id).inserted, let entry = byID[id], isValidQueueTarget(entry.candidate) else { return nil }
        return entry.item
    }
}
