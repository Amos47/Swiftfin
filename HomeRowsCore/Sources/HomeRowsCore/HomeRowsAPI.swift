//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

/// Sends one HomeRows request and returns the status and body for every status. Throws only on network failure or
/// cancellation; a 400's body carries the validation errors, so it must not be dropped.
public protocol HomeRowsTransport: Sendable {
    func send(method: String, path: String, query: [String: String], body: Data?) async throws -> (status: Int, body: Data)
}

public enum HomeRowsError: Error, Equatable {
    case status(Int)
    case invalidResponse
}

public enum HomeRowsSaveResult: Equatable, Sendable {
    case saved
    case invalid([String: [String]])
}

/// Client for the personal fork server's HomeRows API (Custom Home Rows).
public actor HomeRowsAPI {

    public static let apiVersion = 1

    /// Servers known not to have the API (a 404), per server key, for the process.
    private static let unsupported = UnsupportedServers()

    public static func clearSupportCache() async {
        await unsupported.clear()
    }

    private let transport: HomeRowsTransport
    private let serverKey: String

    /// Incremented after every successful change to the user's layout or the household default.
    public private(set) var revision = 0

    public init(transport: HomeRowsTransport, serverKey: String) {
        self.transport = transport
        self.serverKey = serverKey
    }

    /// Whether this server has the fork's HomeRows API. Only a 404 is remembered; other failures are asked again.
    public func isSupported() async -> Bool {
        if await Self.unsupported.contains(serverKey) {
            return false
        }

        guard let response = try? await transport.send(method: "GET", path: "HomeRows/Configuration", query: [:], body: nil) else {
            return false
        }
        if response.status == 404 {
            await Self.unsupported.insert(serverKey)
            return false
        }
        guard (200 ..< 300).contains(response.status),
              let configuration = try? HomeRowConfiguration(json: JSONValue.parse(response.body))
        else { return false }

        return configuration.apiVersion == Self.apiVersion
    }

    public func configuration() async throws -> HomeRowConfiguration {
        try await HomeRowConfiguration(json: JSONValue.parse(get("HomeRows/Configuration")))
    }

    public func providers() async throws -> [HomeRowProvider] {
        let body = try await JSONValue.parse(get("HomeRows/Providers"))
        return try (body.object?["Providers"]?.array ?? []).map(HomeRowProvider.init(json:))
    }

    public func items(rowID: UUID, limit: Int = 20) async throws -> HomeRowItems {
        let body = try await get(
            "HomeRows/\(rowID.uuidString)/Items",
            query: [
                "startIndex": "0",
                "limit": String(limit),
                "fields": "PrimaryImageAspectRatio,Overview",
                "imageTypeLimit": "1",
                "enableImageTypes": "Primary,Backdrop,Thumb,Banner",
                "enableUserData": "true",
            ]
        )
        return try Self.itemsDecoder.decode(HomeRowItems.self, from: body)
    }

    /// Saves the user's own layout.
    public func saveConfiguration(_ rows: [HomeRowInstance]) async throws -> HomeRowsSaveResult {
        try await saveRows("HomeRows/Configuration", rows)
    }

    /// Removes the user's own layout, so they inherit the household default again.
    public func resetConfiguration() async throws {
        try await delete("HomeRows/Configuration")
    }

    /// Saves the household default. Admins only.
    public func saveDefault(_ rows: [HomeRowInstance]) async throws -> HomeRowsSaveResult {
        try await saveRows("HomeRows/DefaultConfiguration", rows)
    }

    /// Removes the household default. Admins only.
    public func removeDefault() async throws {
        try await delete("HomeRows/DefaultConfiguration")
    }

    // MARK: - Requests

    /// Decodes items the way the Jellyfin SDK does, so dates parse.
    private static let itemsDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseJellyfinDate(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date \(text)")
            }
            return date
        }
        return decoder
    }()

    private func get(_ path: String, query: [String: String] = [:]) async throws -> Data {
        let response = try await transport.send(method: "GET", path: path, query: query, body: nil)
        guard (200 ..< 300).contains(response.status) else { throw HomeRowsError.status(response.status) }
        return response.body
    }

    private func delete(_ path: String) async throws {
        let response = try await transport.send(method: "DELETE", path: path, query: [:], body: nil)
        guard (200 ..< 300).contains(response.status) else { throw HomeRowsError.status(response.status) }
        revision += 1
    }

    private func saveRows(_ path: String, _ rows: [HomeRowInstance]) async throws -> HomeRowsSaveResult {
        let body = JSONValue.object(JSONObject([("Rows", .array(rows.map(\.json)))])).serialized()
        let response = try await transport.send(method: "PUT", path: path, query: [:], body: body)

        if response.status == 400 {
            let errors = (try? JSONValue.parse(response.body))?.object?["errors"]?.object
            let mapped = (errors?.entries ?? []).reduce(into: [String: [String]]()) { result, entry in
                result[entry.key] = entry.value.array?.compactMap(\.string) ?? []
            }
            return .invalid(mapped)
        }
        guard (200 ..< 300).contains(response.status) else { throw HomeRowsError.status(response.status) }
        revision += 1
        return .saved
    }
}

/// Parses Jellyfin's ISO 8601 dates, which can have up to 7 fractional digits and may lack a time zone (UTC).
func parseJellyfinDate(_ text: String) -> Date? {
    var value = text
    if let dot = value.firstIndex(of: ".") {
        let fraction = value[value.index(after: dot)...].prefix { $0.isNumber }
        let end = value.index(after: dot)
        let rest = value[value.index(end, offsetBy: fraction.count)...]
        value = String(value[..<dot]) + "." + String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + rest
    }
    if !value.hasSuffix("Z"), value.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) == nil {
        value += "Z"
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    return formatter.date(from: value)
}

private actor UnsupportedServers {

    private var servers: Set<String> = []

    func contains(_ server: String) -> Bool {
        servers.contains(server)
    }

    func insert(_ server: String) {
        servers.insert(server)
    }

    func clear() {
        servers.removeAll()
    }
}
