//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

/// Home screen rules for server home rows. Rows are generic: the server decides what's in them and how they look.

public enum HomeRowStyle: Hashable, Sendable {
    case landscape
    case portrait
    case square
    case libraryButtons
    case libraryTiles
}

/// How to draw a row, from its presentation hint and items. Libraries get the library rows, as on the web.
public func homeRowStyle(presentation: HomeRowPresentation, items: [BaseItemDto]) -> HomeRowStyle {
    let libraryKinds: Set<BaseItemKind> = [.collectionFolder, .userView]

    if presentation.cardShape == "Button" {
        return .libraryButtons
    }
    if !items.isEmpty, items.allSatisfy({ $0.type.map(libraryKinds.contains) ?? false }) {
        return .libraryTiles
    }
    switch presentation.cardShape {
    case "Poster": return .portrait
    case "Square": return .square
    default: return .landscape
    }
}

/// Hidden rows take no space: disabled, unavailable, failed, needing configuration, or empty.
public func isRowShown(row: HomeRowInstance, items: HomeRowItems?) -> Bool {
    guard row.enabled, row.isAvailable, let items else { return false }
    return items.error == nil && !items.items.isEmpty
}

public func homeRowTitle(row: HomeRowInstance, items: HomeRowItems, provider: HomeRowProvider?) -> String {
    if let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
        return title
    }
    if let title = items.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return title
    }
    return provider?.name ?? row.provider
}

public struct LoadedHomeRow: Sendable {

    public let row: HomeRowInstance
    public let items: HomeRowItems
    public let title: String
    public let style: HomeRowStyle
}

/// Loads the layout and every shown row's first page, in parallel. Returns nil on a stock server, or when the layout
/// can't be loaded, so the caller keeps the stock home screen. A row that fails or takes longer than `timeout` is left
/// out; its request is cancelled.
public func loadHomeRows(api: HomeRowsAPI, timeout: Duration = .seconds(10)) async -> [LoadedHomeRow]? {
    guard await api.isSupported(), let configuration = try? await api.configuration() else { return nil }

    async let providerList = try? api.providers()
    let candidates = configuration.rows.enumerated().filter { $0.element.enabled && $0.element.isAvailable }

    let loaded = await withTaskGroup(of: (Int, HomeRowItems?).self) { group in
        for (index, row) in candidates {
            group.addTask {
                await (index, withTimeout(timeout) { try await api.items(rowID: row.id) })
            }
        }
        var results: [Int: HomeRowItems] = [:]
        for await (index, items) in group {
            results[index] = items
        }
        return results
    }

    let providers = await providerList ?? []

    return candidates.compactMap { index, row in
        guard let items = loaded[index], isRowShown(row: row, items: items) else { return nil }
        let provider = providers.first { $0.id == row.provider }
        return LoadedHomeRow(
            row: row,
            items: items,
            title: homeRowTitle(row: row, items: items, provider: provider),
            style: homeRowStyle(presentation: items.presentation, items: items.items)
        )
    }
}

/// Runs `operation`, giving up after `timeout`. Failures and timeouts give nil; the loser is cancelled.
func withTimeout<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await operation() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
