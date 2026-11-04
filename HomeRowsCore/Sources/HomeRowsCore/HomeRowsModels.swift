//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

/// DTOs of the personal fork server's HomeRows API (Custom Home Rows). JSON is PascalCase.

/// The id sent for new rows; the server assigns a real one on save.
public let emptyRowID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

/// One row of a layout (server `HomeRowInstanceDto`).
public struct HomeRowInstance: Hashable, Sendable {

    public var id: UUID
    public var provider: String
    public var title: String?
    public var config: [String: JSONValue]
    public var enabled: Bool
    public var isAvailable: Bool

    public init(
        id: UUID,
        provider: String,
        title: String? = nil,
        config: [String: JSONValue] = [:],
        enabled: Bool = true,
        isAvailable: Bool = true
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.config = config
        self.enabled = enabled
        self.isAvailable = isAvailable
    }

    init(json: JSONValue) throws {
        guard let object = json.object,
              let id = object["Id"]?.string.flatMap(UUID.init(uuidString:)),
              let provider = object["Provider"]?.string
        else { throw HomeRowsError.invalidResponse }

        self.init(
            id: id,
            provider: provider,
            title: object["Title"]?.string,
            config: object["Config"]?.object?.dictionary ?? [:],
            enabled: object["Enabled"]?.bool ?? true,
            isAvailable: object["IsAvailable"]?.bool ?? true
        )
    }

    /// The body sent to the server. `Title` and `Enabled` are always written: the server reads a missing `Enabled`
    /// as false, which would hide the row.
    var json: JSONValue {
        .object(JSONObject([
            ("Id", .string(id.uuidString)),
            ("Provider", .string(provider)),
            ("Title", title.map(JSONValue.string) ?? .null),
            ("Config", .object(JSONObject(config.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))),
            ("Enabled", .bool(enabled)),
        ]))
    }
}

/// The user's effective layout (server `HomeRowConfigurationDto`).
public struct HomeRowConfiguration: Hashable, Sendable {

    public var apiVersion: Int
    public var source: String
    public var isCustomized: Bool
    public var rows: [HomeRowInstance]

    public init(apiVersion: Int, source: String, isCustomized: Bool, rows: [HomeRowInstance]) {
        self.apiVersion = apiVersion
        self.source = source
        self.isCustomized = isCustomized
        self.rows = rows
    }

    init(json: JSONValue) throws {
        guard let object = json.object, let apiVersion = object["ApiVersion"]?.int else { throw HomeRowsError.invalidResponse }
        try self.init(
            apiVersion: apiVersion,
            source: object["Source"]?.string ?? "",
            isCustomized: object["IsCustomized"]?.bool ?? false,
            rows: (object["Rows"]?.array ?? []).map(HomeRowInstance.init(json:))
        )
    }
}

/// A row type the server offers (server `HomeRowProviderDto`). `schema` keeps the server's property order.
public struct HomeRowProvider: Hashable, Sendable {

    public var id: String
    public var name: String
    public var description: String
    public var schema: JSONObject
    public var defaults: [String: JSONValue]

    public init(id: String, name: String, description: String = "", schema: JSONObject = .init(), defaults: [String: JSONValue] = [:]) {
        self.id = id
        self.name = name
        self.description = description
        self.schema = schema
        self.defaults = defaults
    }

    init(json: JSONValue) throws {
        guard let object = json.object, let id = object["Id"]?.string else { throw HomeRowsError.invalidResponse }
        self.init(
            id: id,
            name: object["Name"]?.string ?? id,
            description: object["Description"]?.string ?? "",
            schema: object["Schema"]?.object ?? .init(),
            defaults: object["Defaults"]?.object?.dictionary ?? [:]
        )
    }
}

/// How a row asks to be drawn (server `HomeRowPresentation`).
public struct HomeRowPresentation: Codable, Hashable, Sendable {

    public var cardShape: String
    public var preferredImageType: String?
    public var fallbackImageType: String?

    public init(cardShape: String, preferredImageType: String? = nil, fallbackImageType: String? = nil) {
        self.cardShape = cardShape
        self.preferredImageType = preferredImageType
        self.fallbackImageType = fallbackImageType
    }

    enum CodingKeys: String, CodingKey {
        case cardShape = "CardShape"
        case preferredImageType = "PreferredImageType"
        case fallbackImageType = "FallbackImageType"
    }
}

/// One page of a row's items (server `HomeRowItemsDto`).
public struct HomeRowItems: Decodable, Sendable {

    public var rowID: UUID
    public var title: String?
    public var items: [BaseItemDto]
    public var totalRecordCount: Int?
    public var startIndex: Int
    public var presentation: HomeRowPresentation
    public var error: String?

    public init(
        rowID: UUID,
        title: String? = nil,
        items: [BaseItemDto] = [],
        totalRecordCount: Int? = nil,
        startIndex: Int = 0,
        presentation: HomeRowPresentation,
        error: String? = nil
    ) {
        self.rowID = rowID
        self.title = title
        self.items = items
        self.totalRecordCount = totalRecordCount
        self.startIndex = startIndex
        self.presentation = presentation
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case rowID = "RowId"
        case title = "Title"
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
        case startIndex = "StartIndex"
        case presentation = "Presentation"
        case error = "Error"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rowID = try container.decode(UUID.self, forKey: .rowID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        items = try container.decodeIfPresent([BaseItemDto].self, forKey: .items) ?? []
        totalRecordCount = try container.decodeIfPresent(Int.self, forKey: .totalRecordCount)
        startIndex = try container.decodeIfPresent(Int.self, forKey: .startIndex) ?? 0
        presentation = try container.decode(HomeRowPresentation.self, forKey: .presentation)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}
