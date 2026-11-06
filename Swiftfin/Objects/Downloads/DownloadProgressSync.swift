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

    /// Marks a download watched, for Next & delete and Delete, which only show once it's been watched to the end.
    func markWatched(itemID: String?) {
        guard var record = store.record(for: itemID) else { return }
        record.localPlayed = true
        record.localPositionTicks = 0
        record.localPlayedAt = .now
        store.upsert(record)
    }

    /// Before playing a download online, takes the server's position if it's newer (watched elsewhere since). Gives up
    /// after two seconds, so it never holds up playing offline.
    func refreshResumePosition(itemID: String?) async {
        guard let itemID, let userSession = Container.shared.currentUserSession(), store.record(for: itemID) != nil else { return }

        let serverData = await withTaskGroup(of: UserItemDataDto?.self) { group in
            group.addTask {
                try? await userSession.client.send(Paths.getItemUserData(itemID: itemID, userID: userSession.user.id)).value
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let serverData, var record = store.record(for: itemID),
              resumeSource(localPlayedAt: record.localPlayedAt, serverLastPlayed: serverData.lastPlayedDate) == .server
        else { return }

        record.item.userData = serverData
        record.localPlayedAt = nil
        record.localPositionTicks = nil
        record.localPlayed = false
        store.upsert(record)
    }

    /// Sends offline progress to the server, where it's newer than the server's: for downloads, and for deleted ones.
    func syncIfPossible() async {
        guard !isSyncing, let userSession = Container.shared.currentUserSession() else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            for progress in store.records.compactMap(\.pendingProgress) {
                let serverData = try await send(progress, userSession: userSession)

                // Re-read: it may have been watched further while this was sending.
                guard var record = store.record(for: progress.id), record.localPlayedAt == progress.playedAt else { continue }
                record.item.userData = serverData
                record.localPlayedAt = nil
                record.localPositionTicks = nil
                record.localPlayed = false
                store.upsert(record)
            }

            for progress in store.pendingProgress {
                _ = try await send(progress, userSession: userSession)
                store.pendingProgress = store.pendingProgress.filter { $0 != progress }
            }
        } catch {
            // Probably offline: try again next time.
            logger.debug("Download progress not synced: \(error.localizedDescription)")
        }
    }

    /// Sends `progress` if it's newer than the server's, and returns the server's user data afterwards.
    private func send(_ progress: PendingProgress, userSession: UserSession) async throws -> UserItemDataDto {
        let client = userSession.client
        let serverData = try await client.send(Paths.getItemUserData(itemID: progress.id, userID: userSession.user.id)).value

        let decision = progressSyncDecision(
            localPlayedAt: progress.playedAt,
            downloadedAt: progress.downloadedAt,
            serverLastPlayed: serverData.lastPlayedDate
        )
        guard decision == .sendLocal else { return serverData }

        let body = UpdateUserItemDataDto(
            isPlayed: progress.played,
            lastPlayedDate: progress.playedAt,
            playbackPositionTicks: progress.positionTicks
        )
        return try await client.send(Paths.updateItemUserData(itemID: progress.id, userID: userSession.user.id, body)).value
    }
}
