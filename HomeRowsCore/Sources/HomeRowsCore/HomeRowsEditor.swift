//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation

/// The rows editor's working copy (Custom Home Rows). Edits stay pending in memory until `save()`.

public let maxHomeRows = 20
public let maxHomeRowTitle = 100

/// Errors that name no row are kept under this key.
public let generalErrorsKey = "*"

/// A row in the editor. `key` is client-only and stable while editing; new rows all share `emptyRowID`.
public struct EditorRow: Identifiable, Hashable, Sendable {

    public let key: String
    public var row: HomeRowInstance

    public var id: String {
        key
    }
}

/// The choices when leaving the editor with unsaved edits.
public enum LeaveChoice: Sendable {
    case save
    case discard
    case keepEditing
}

/// Maps a 400's errors to rows: "rows[2].Limit" → the third row's key → ["limit": message].
public func mapSaveErrors(rows: [EditorRow], errors: [String: [String]]) -> [String: [String: String]] {
    let indexedErrorKey = /^rows\[(\d+)\]\.(.+)$/.ignoresCase()
    var mapped: [String: [String: String]] = [:]
    for (name, messages) in errors {
        let message = messages.first ?? ""
        if let match = name.wholeMatch(of: indexedErrorKey), let index = Int(match.1), rows.indices.contains(index) {
            let setting = String(match.2)
            let key = setting.prefix(1).lowercased() + setting.dropFirst()
            mapped[rows[index].key, default: [:]][key] = message
        } else {
            mapped[generalErrorsKey, default: [:]][name] = message
        }
    }
    return mapped
}

@MainActor
public final class HomeRowsEditor: ObservableObject {

    @Published
    public private(set) var loaded = false
    @Published
    public private(set) var rows: [EditorRow] = []
    @Published
    public private(set) var providers: [HomeRowProvider] = []
    @Published
    public private(set) var source = ""
    /// Row key → setting key → message, from the server's validation errors. `generalErrorsKey` holds the rest.
    @Published
    public private(set) var errors: [String: [String: String]] = [:]
    @Published
    public private(set) var generalError: String?
    @Published
    public private(set) var isBusy = false

    private let api: HomeRowsAPI
    private var savedRows: [HomeRowInstance] = []
    private var nextKey = 0

    public init(api: HomeRowsAPI) {
        self.api = api
    }

    public var hasPendingEdits: Bool {
        snapshot(rows.map(\.row)) != snapshot(savedRows)
    }

    public func provider(_ id: String) -> HomeRowProvider? {
        providers.first { $0.id == id }
    }

    /// Local validation of a row against its provider's schema; empty for unavailable rows.
    public func validation(_ row: EditorRow) -> [String: HomeRowFieldError] {
        guard let provider = provider(row.row.provider) else { return [:] }
        return validateRowConfig(provider.fields(), row.row.config)
    }

    // MARK: - Loading

    public func load() async throws {
        async let configuration = api.configuration()
        async let providerList = api.providers()
        let (loadedConfiguration, loadedProviders) = try await (configuration, providerList)
        providers = loadedProviders
        apply(loadedConfiguration)
    }

    private func apply(_ configuration: HomeRowConfiguration) {
        savedRows = configuration.rows
        rows = editorRows(configuration.rows)
        source = configuration.source
        errors = [:]
        generalError = nil
        loaded = true
    }

    private func editorRows(_ rows: [HomeRowInstance]) -> [EditorRow] {
        rows.map { row in
            nextKey += 1
            return EditorRow(key: "r\(nextKey)", row: row)
        }
    }

    // MARK: - Edits

    private func update(_ key: String, _ change: (inout HomeRowInstance) -> Void) {
        guard let index = rows.firstIndex(where: { $0.key == key }) else { return }
        change(&rows[index].row)
    }

    /// Drag-and-drop move, with `List.onMove` semantics.
    public func moveRow(from source: IndexSet, to destination: Int) {
        var moved = rows
        let picked = source.sorted().map { moved[$0] }
        for index in source.sorted(by: >) {
            moved.remove(at: index)
        }
        let insertAt = destination - source.filter { $0 < destination }.count
        moved.insert(contentsOf: picked, at: max(0, min(insertAt, moved.count)))
        rows = moved
    }

    /// Moves a row one place up (-1) or down (1). No-op at the ends.
    public func move(key: String, by delta: Int) {
        guard let from = rows.firstIndex(where: { $0.key == key }) else { return }
        let to = from + delta
        guard rows.indices.contains(to) else { return }
        rows.swapAt(from, to)
    }

    public func remove(key: String) {
        rows.removeAll { $0.key == key }
    }

    /// Appends a new row of the provider with its defaults. Returns its key, or nil when the layout is full.
    @discardableResult
    public func add(providerID: String) -> String? {
        guard rows.count < maxHomeRows, let provider = provider(providerID) else { return nil }
        let added = editorRows([HomeRowInstance(id: emptyRowID, provider: provider.id, config: provider.defaults)])
        rows += added
        return added.first?.key
    }

    public func setEnabled(key: String, _ enabled: Bool) {
        update(key) { $0.enabled = enabled }
    }

    /// Sets the custom title. Blank means the default; longer titles are cut to `maxHomeRowTitle`.
    public func setTitle(key: String, _ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        update(key) { $0.title = trimmed.isEmpty ? nil : String(trimmed.prefix(maxHomeRowTitle)) }
    }

    /// Sets one setting; nil removes it so the provider default applies.
    public func setValue(key: String, setting: String, _ value: JSONValue?) {
        update(key) { $0.config[setting] = value }
    }

    // MARK: - Server actions

    /// Sends the rows. Returns true when saved; otherwise the edits stay, with the errors set.
    public func save() async -> Bool {
        await run {
            switch try await self.api.saveConfiguration(self.rows.map(\.row)) {
            case .saved:
                try await self.apply(self.api.configuration())
                return true
            case let .invalid(errors):
                self.errors = mapSaveErrors(rows: self.rows, errors: errors)
                return false
            }
        }
    }

    /// Drops the edits.
    public func discard() {
        rows = editorRows(savedRows)
        errors = [:]
        generalError = nil
    }

    /// Removes the user's own layout and shows the inherited one. Pending edits are dropped.
    public func reset() async -> Bool {
        await run {
            try await self.api.resetConfiguration()
            try await self.apply(self.api.configuration())
            return true
        }
    }

    /// Saves the current rows, saved or not, as the household default. The user's own layout is unchanged.
    public func saveAsDefault() async -> Bool {
        await run {
            switch try await self.api.saveDefault(self.rows.map(\.row)) {
            case .saved:
                return true
            case let .invalid(errors):
                self.errors = mapSaveErrors(rows: self.rows, errors: errors)
                return false
            }
        }
    }

    public func removeDefault() async -> Bool {
        await run {
            try await self.api.removeDefault()
            return true
        }
    }

    /// Applies a choice from the unsaved-edits prompt. Returns true when the user may leave.
    public func resolveLeave(_ choice: LeaveChoice) async -> Bool {
        switch choice {
        case .save:
            return await save()
        case .discard:
            discard()
            return true
        case .keepEditing:
            return false
        }
    }

    /// Runs one server action at a time, clearing the previous errors. A thrown error becomes `generalError`.
    private func run(_ action: () async throws -> Bool) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        errors = [:]
        generalError = nil
        do {
            return try await action()
        } catch {
            generalError = String(describing: error)
            return false
        }
    }

    // MARK: - Comparing

    private struct Snapshot: Equatable {
        let id: UUID
        let provider: String
        let title: String?
        let enabled: Bool
        let config: [String: JSONValue]
    }

    /// Rows compared by effective setting values, so a settings screen writing back a default isn't an edit.
    private func snapshot(_ rows: [HomeRowInstance]) -> [Snapshot] {
        rows.map { row in
            var config = row.config
            for field in provider(row.provider)?.fields() ?? [] {
                let value = field.effectiveValue(in: row.config)
                config[field.key] = field.kind == .boolean ? .bool(value?.bool ?? false) : value
            }
            config = config.filter { $0.value != .null && $0.value != .string("") }
            let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Snapshot(
                id: row.id,
                provider: row.provider,
                title: title?.isEmpty == false ? title : nil,
                enabled: row.enabled,
                config: config
            )
        }
    }
}
