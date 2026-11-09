//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import HomeRowsCore

// Personal fork: Custom Home Rows.

/// One `HomeRowsAPI` per signed-in user on a server, shared by the home screen and the editor, so a save in the
/// editor is seen by the home screen (`HomeRowsAPI.revision`).
@MainActor
enum HomeRowsService {

    private static var apis: [String: HomeRowsAPI] = [:]
    private static var editors: [ObjectIdentifier: HomeRowsEditor] = [:]
    private static var itemActionAPIs: [String: ItemActionsAPI] = [:]
    private static var discoveryListAPIs: [String: DiscoveryListAPI] = [:]

    /// One rows editor per API, so leaving the editor by any route (tvOS Menu, a tab switch) keeps unsaved edits
    /// for when it's opened again, instead of throwing them away with the screen.
    static func editor(for api: HomeRowsAPI) -> HomeRowsEditor {
        let key = ObjectIdentifier(api)
        if let editor = editors[key] {
            return editor
        }
        let editor = HomeRowsEditor(api: api)
        editors[key] = editor
        return editor
    }

    /// The item actions client, on the same transport (and so the same session's credentials) as the HomeRows API.
    static func itemActions(for session: UserSession) -> ItemActionsAPI {
        let key = key(for: session)
        if let api = itemActionAPIs[key] {
            return api
        }

        let api = ItemActionsAPI(transport: JellyfinHomeRowsTransport(configuration: session.client.configuration))
        itemActionAPIs[key] = api
        return api
    }

    /// The discovery list pages client, on the same transport.
    static func discoveryLists(for session: UserSession) -> DiscoveryListAPI {
        let key = key(for: session)
        if let api = discoveryListAPIs[key] {
            return api
        }

        let api = DiscoveryListAPI(transport: JellyfinHomeRowsTransport(configuration: session.client.configuration))
        discoveryListAPIs[key] = api
        return api
    }

    // The token is part of the key: the transport sends the token it was created with, so signing in again (a new
    // token) must not reuse an API that would keep getting 401s.
    private static func key(for session: UserSession) -> String {
        let configuration = session.client.configuration
        return [configuration.url.absoluteString, session.user.id, configuration.accessToken ?? ""].joined(separator: "|")
    }

    static func api(for session: UserSession) -> HomeRowsAPI {
        let configuration = session.client.configuration
        let serverKey = configuration.url.absoluteString
        let key = key(for: session)
        if let api = apis[key] {
            return api
        }

        let api = HomeRowsAPI(
            transport: JellyfinHomeRowsTransport(configuration: session.client.configuration),
            serverKey: serverKey
        )
        apis[key] = api
        return api
    }
}
