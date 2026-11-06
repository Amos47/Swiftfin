//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import FactoryKit
import Foundation
import Network
import UIKit

extension Container {

    var serverReachability: Factory<ServerReachability> {
        self { @MainActor in ServerReachability() }
            .singleton
    }
}

/// Personal fork: whether the signed-in server answers, so Home can say "You're offline" instead of loading forever.
/// Checked at start, when the app comes back, when the network changes, and every 10 seconds while unreachable.
@MainActor
final class ServerReachability: ObservableObject {

    @Published
    private(set) var isReachable = true

    private let monitor = NWPathMonitor()
    private var cancellables: Set<AnyCancellable> = []
    private var retryTask: Task<Void, Never>?
    private var isChecking = false

    init() {
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { await self?.check() }
            }
            .store(in: &cancellables)

        Container.shared.userSessionManager().$currentSession
            .compactMap(\.self)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.check() }
            }
            .store(in: &cancellables)

        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    func check() async {
        guard !isChecking, let client = Container.shared.currentUserSession()?.client else { return }
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: client.configuration.url.appendingPathComponent("System/Ping"))
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let reachable = if let (_, response) = try? await URLSession.shared.data(for: request),
                           let status = (response as? HTTPURLResponse)?.statusCode
        {
            status < 500
        } else {
            false
        }

        if reachable != isReachable {
            isReachable = reachable
        }
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        guard !isReachable else { return }

        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.check()
        }
    }
}
