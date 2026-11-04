//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

@MainActor
final class NavigationCoordinator: ObservableObject {

    struct PresentedRoute: Identifiable {

        let route: NavigationRoute
        let coordinator: NavigationCoordinator

        var id: String {
            route.id
        }
    }

    @Published
    var path: [NavigationRoute] = []

    @Published
    var presentedSheet: PresentedRoute?
    @Published
    var presentedFullScreen: PresentedRoute?

    /// Personal fork: the coordinator that presented this one full screen, so the video player can leave the series
    /// page underneath when it closes.
    weak var presenter: NavigationCoordinator?

    func push(
        _ route: NavigationRoute
    ) {
        #if os(tvOS)
        if let presentedCoordinator = presentedFullScreen?.coordinator ?? presentedSheet?.coordinator {
            presentedCoordinator.push(route)
            return
        }

        switch route.transitionStyle {
        case .push, .sheet:
            presentedSheet = .init(
                route: route,
                coordinator: .init()
            )
        case .fullscreen:
            presentedFullScreen = .init(
                route: route,
                coordinator: .init()
            )
        }
        #else
        switch route.transitionStyle {
        case .push:
            path.append(route)
        case .sheet:
            presentedSheet = .init(
                route: route,
                coordinator: .init()
            )
        case .fullscreen:
            let coordinator = NavigationCoordinator()
            coordinator.presenter = self
            withAnimation {
                presentedFullScreen = .init(
                    route: route,
                    coordinator: coordinator
                )
            }
        }
        #endif
    }
}
