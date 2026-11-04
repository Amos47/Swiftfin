//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import HomeRowsCore
import JellyfinAPI

// Personal fork: Custom Home Rows.

/// Sends HomeRows requests with the session's server URL and credentials. It goes through `URLSession` rather than
/// `JellyfinClient.send`, because Get's response validation throws on non-2xx statuses and drops the body, and a 400's
/// body carries the validation errors to show on the rows. `URLSession`'s async API honours task cancellation, so
/// row timeouts cancel the request.
struct JellyfinHomeRowsTransport: HomeRowsTransport {

    let configuration: JellyfinClient.Configuration
    let session: URLSession

    init(configuration: JellyfinClient.Configuration, session: URLSession = URLSession(configuration: .swiftfin)) {
        self.configuration = configuration
        self.session = session
    }

    /// The `Authorization` header the Jellyfin SDK sends (its own builder is internal).
    var authorizationHeader: String {
        var fields = [
            ("DeviceId", configuration.deviceID),
            ("Device", configuration.deviceName),
            ("Client", configuration.client),
            ("Version", configuration.version),
        ]
        if let token = configuration.accessToken {
            fields.append(("Token", token))
        }
        return "MediaBrowser " + fields.map { "\($0.0)=\"\($0.1)\"" }.joined(separator: ", ")
    }

    func send(method: String, path: String, query: [String: String], body: Data?) async throws -> (status: Int, body: Data) {
        var components = URLComponents(url: configuration.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            components?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
