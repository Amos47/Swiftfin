//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import HomeRowsCore
import SwiftUI

// Personal fork: Custom Home Rows.

/// The Home section of Customize: on a server with HomeRows, a link to the rows editor in place of the local home
/// toggles (the server's rows have their own settings); otherwise Swiftfin's own Home section.
struct HomeRowsAwareHomeSection: View {

    @Injected(\.currentUserSession)
    private var userSession: UserSession?

    @Router
    private var router

    @State
    private var isSupported: Bool?

    var body: some View {
        Group {
            if isSupported == true, let userSession {
                Section(L10n.home) {
                    ChevronButton(L10n.homeScreenRows) {
                        router.route(to: .homeRowsEditor(
                            api: HomeRowsService.api(for: userSession),
                            isAdmin: userSession.user.data.policy?.isAdministrator == true
                        ))
                    }
                }
            } else {
                CustomizeViewsSettings.HomeSection()
            }
        }
        .task {
            guard let userSession else { return }
            isSupported = await HomeRowsService.api(for: userSession).isSupported()
        }
    }
}

extension NavigationRoute {

    @MainActor
    static func homeRowsEditor(api: HomeRowsAPI, isAdmin: Bool) -> NavigationRoute {
        let editor = HomeRowsEditor(api: api)
        return NavigationRoute(id: "homeRowsEditor") {
            HomeRowsEditorView(editor: editor, isAdmin: isAdmin)
        }
    }

    static func homeRow(editor: HomeRowsEditor, key: String) -> NavigationRoute {
        NavigationRoute(id: "homeRow-\(key)") {
            HomeRowView(editor: editor, key: key)
        }
    }

    static func homeRowOptions(editor: HomeRowsEditor, key: String, field: HomeRowField) -> NavigationRoute {
        NavigationRoute(id: "homeRowOptions-\(key)-\(field.key)") {
            HomeRowMultiOptionView(editor: editor, key: key, field: field)
        }
    }
}

extension HomeRowFieldError {

    var displayTitle: String {
        switch self {
        case .required: L10n.homeRowsErrorRequired
        case .outOfRange: L10n.homeRowsErrorOutOfRange
        case .tooLong: L10n.homeRowsErrorTooLong
        case .unknownOption: L10n.homeRowsErrorUnknownOption
        case .pickAtLeastOne: L10n.homeRowsErrorPickAtLeastOne
        }
    }
}
