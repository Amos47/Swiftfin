//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Provider schemas (a JSON schema subset) to settings fields, with the same rules as the web client's
/// `homeRowsSchema.ts` and the Android TV client's `HomeRowsSchema.kt`. Knows nothing about particular providers.

public enum HomeRowFieldKind: Hashable, Sendable {
    case boolean
    case integer
    case string
    case enumeration
    case multiEnumeration
}

public struct HomeRowOption: Hashable, Sendable {

    public let value: String
    public let label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// One setting of a provider, ready to become a settings control.
public struct HomeRowField: Hashable, Sendable {

    public let key: String
    public let kind: HomeRowFieldKind
    public let label: String
    public let required: Bool
    public let min: Int?
    public let max: Int?
    public let maxLength: Int?
    public let minItems: Int?
    public let options: [HomeRowOption]
    public let defaultValue: JSONValue?
}

public enum HomeRowFieldError: Hashable, Sendable {
    case required
    case outOfRange
    case tooLong
    case unknownOption
    case pickAtLeastOne
}

private extension JSONObject {

    func strings(_ key: String) -> [String]? {
        self[key]?.array?.compactMap(\.string)
    }
}

private func kind(of property: JSONObject) -> HomeRowFieldKind {
    switch property["type"]?.string {
    case "boolean": .boolean
    case "integer": .integer
    case "array": .multiEnumeration
    default: property.strings("enum") != nil ? .enumeration : .string
    }
}

private func options(of property: JSONObject, kind: HomeRowFieldKind) -> [HomeRowOption] {
    let values = kind == .multiEnumeration ? property["items"]?.object?.strings("enum") : property.strings("enum")
    let labels = property.strings("x-enumLabels") ?? []
    return (values ?? []).enumerated().map { index, value in
        HomeRowOption(value: value, label: index < labels.count ? labels[index] : value)
    }
}

public extension HomeRowProvider {

    /// The provider's settings, in schema property order. Unknown types become strings.
    func fields() -> [HomeRowField] {
        let required = schema.strings("required") ?? []
        guard let properties = schema["properties"]?.object else { return [] }

        return properties.entries.compactMap { key, value in
            guard let property = value.object else { return nil }
            let kind = kind(of: property)
            return HomeRowField(
                key: key,
                kind: kind,
                label: property["title"]?.string ?? key,
                required: required.contains(key),
                min: property["minimum"]?.int,
                max: property["maximum"]?.int,
                maxLength: property["maxLength"]?.int,
                minItems: property["minItems"]?.int,
                options: options(of: property, kind: kind),
                defaultValue: defaults[key] ?? property["default"]
            )
        }
    }
}

public extension HomeRowField {

    /// The value a setting has for a row: its config value, else the provider default.
    func effectiveValue(in config: [String: JSONValue]) -> JSONValue? {
        if let value = config[key], value != .null {
            return value
        }
        if let defaultValue, defaultValue != .null {
            return defaultValue
        }
        return nil
    }

    func isOption(_ value: JSONValue) -> Bool {
        guard let text = value.string else { return false }
        return options.contains { $0.value == text }
    }

    fileprivate func validate(_ value: JSONValue?) -> HomeRowFieldError? {
        guard let value, value.string != "" else { return required ? .required : nil }

        switch kind {
        case .integer:
            guard let number = value.int else { return .outOfRange }
            if let min, number < min {
                return .outOfRange
            }
            if let max, number > max {
                return .outOfRange
            }
            return nil
        case .string:
            let length = value.string?.count ?? 0
            if let maxLength, length > maxLength {
                return .tooLong
            }
            return nil
        case .enumeration:
            return isOption(value) ? nil : .unknownOption
        case .multiEnumeration:
            let values = value.array ?? []
            if let minItems, values.count < minItems {
                return .pickAtLeastOne
            }
            return values.allSatisfy(isOption) ? nil : .unknownOption
        case .boolean:
            return nil
        }
    }
}

/// A row's setting problems, setting key → error. Empty when valid.
public func validateRowConfig(_ fields: [HomeRowField], _ config: [String: JSONValue]) -> [String: HomeRowFieldError] {
    fields.reduce(into: [:]) { errors, field in
        if let error = field.validate(field.effectiveValue(in: config)) {
            errors[field.key] = error
        }
    }
}

/// The editor's label for a row: its custom title, else the provider name plus the labels of its required pick-one
/// settings ("Recently Added · Shows"), else the provider id when the provider is gone.
public func editorRowLabel(row: HomeRowInstance, provider: HomeRowProvider?) -> String {
    if let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
        return title
    }
    guard let provider else { return row.provider }

    let choices = provider.fields()
        .filter { $0.kind == .enumeration && $0.required }
        .compactMap { field -> String? in
            let value = field.effectiveValue(in: row.config)?.string
            return field.options.first { $0.value == value }?.label
        }

    return ([provider.name] + choices).joined(separator: " · ")
}
