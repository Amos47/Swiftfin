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
import JellyfinAPI
import Logging
import PlayerCore
import UIKit

extension Container {

    var downloadProgressSync: Factory<DownloadProgressSync> {
        self { @MainActor in DownloadProgressSync() }
            .singleton
    }
}

/// Personal fork: watch progress for downloads. It's saved with the download while watching (the server may be out of
/// reach), and sent to the server when it can be reached again, unless the server has newer progress.
@MainActor
final class DownloadProgressSync {

    /// Past this share of the runtime, a download counts as watched, as on the server.
    private static let playedThreshold = 0.9

    @Injected(\.downloadStore)
    private var store: DownloadStore

    private let logger = Logger.swiftfin()
    private var cancellables: Set<AnyCancellable> = []
    private var isSyncing = false

    init() {
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { await self?.syncIfPossible() }
            }
            .store(in: &cancellables)

        Container.shared.userSessionManager().$currentSession
            .compactMap(\.self)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.syncIfPossible() }
            }
            .store(in: &cancellables)
    }

    /// Saves the position of a download being watched.
    func record(itemID: String?, positionTicks: Int?, runtimeTicks: Int?) {
        guard var record = store.record(for: itemID), let positionTicks else { return }

        if let runtimeTicks, runtimeTicks > 0, Double(positionTicks) / Double(runtimeTicks) >= Self.playedThreshold {
            record.localPlayed = true
            record.localPositionTicks = 0
        } else {
            record.localPlayed = false
            record.localPositionTicks = positionTicks
        }
        record.localPlayedAt = .now
        store.upsert(record)
    }

    /// Sends offline progress to the server, where it's newer than the server's.
    func syncIfPossible() async {
        guard !isSyncing, let userSession = Container.shared.currentUserSession() else { return }
        isSyncing = true
        defer { isSyncing = false }

        for record in store.records where record.localPlayedAt != nil {
            do {
                try await sync(record, userSession: userSession)
            } catch {
                // Probably offline: try again next time.
                logger.debug("Download progress not synced: \(error.localizedDescription)")
                return
            }
        }
    }

    private func sync(_ record: DownloadRecord, userSession: UserSession) async throws {
        let client = userSession.client
        let serverData = try await client.send(Paths.getItemUserData(itemID: record.id, userID: userSession.user.id)).value

        var updated = record
        let decision = progressSyncDecision(
            localPlayedAt: record.localPlayedAt,
            downloadedAt: record.downloadedAt,
            serverLastPlayed: serverData.lastPlayedDate
        )

        switch decision {
        case .sendLocal:
            let body = UpdateUserItemDataDto(
                isPlayed: record.localPlayed,
                lastPlayedDate: record.localPlayedAt,
                playbackPositionTicks: record.localPositionTicks ?? 0
            )
            let saved = try await client.send(Paths.updateItemUserData(itemID: record.id, userID: userSession.user.id, body)).value
            updated.item.userData = saved
        case .keepServer:
            updated.item.userData = serverData
        }

        // The download now resumes from what the server has.
        updated.localPlayedAt = nil
        updated.localPositionTicks = nil
        updated.localPlayed = false
        store.upsert(updated)
    }
}
