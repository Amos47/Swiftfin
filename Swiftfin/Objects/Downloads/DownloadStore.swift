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
import Logging

extension Container {

    var downloadStore: Factory<DownloadStore> {
        self { @MainActor in DownloadStore() }
            .singleton
    }
}

/// Personal fork: the current user's downloads, kept on disk at
/// `Application Support/Downloads/<serverID>/<userID>/<itemID>/` (`record.json` and images).
@MainActor
final class DownloadStore: ObservableObject {

    enum Image: String {
        /// The episode's own image, or the movie's backdrop.
        case thumb
        /// The movie's poster.
        case primary
        /// The episode's series poster.
        case series
    }

    @Published
    private(set) var records: [DownloadRecord] = [] {
        didSet {
            PlaybackEngine.downloadedItemIDs = Set(records.filter(\.isComplete).map(\.id))
        }
    }

    /// The finished downloads of `seriesID`, in season and episode order.
    func episodes(ofSeries seriesID: String?) -> [DownloadRecord] {
        guard let seriesID else { return [] }
        return records
            .filter { $0.isComplete && $0.item.seriesID == seriesID }
            .sorted {
                ($0.item.parentIndexNumber ?? 0, $0.item.indexNumber ?? 0) < ($1.item.parentIndexNumber ?? 0, $1.item.indexNumber ?? 0)
            }
    }

    private(set) var serverID: String?
    private(set) var userID: String?

    private let logger = Logger.swiftfin()
    private var sessionCancellable: AnyCancellable?

    private static let root = URL.applicationSupportDirectory.appendingPathComponent("Downloads", isDirectory: true)

    init() {
        let manager = Container.shared.userSessionManager()
        sessionCancellable = manager.$currentSession
            .map { ($0?.server.id, $0?.user.id) }
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] serverID, userID in
                self?.reload(serverID: serverID, userID: userID)
            }
    }

    func record(for itemID: String?) -> DownloadRecord? {
        guard let itemID else { return nil }
        return records.first { $0.id == itemID }
    }

    /// Saves `record` and publishes it. Records for another server or user are written but not published.
    func upsert(_ record: DownloadRecord) {
        do {
            let folder = Self.folder(serverID: record.serverID, userID: record.userID, itemID: record.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: folder.appendingPathComponent("record.json"), options: .atomic)
        } catch {
            logger.error("Unable to save download record: \(error.localizedDescription)")
        }

        guard record.serverID == serverID, record.userID == userID else { return }

        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    /// Updates the published record without writing it, for frequent changes such as download progress.
    func updateInMemory(_ record: DownloadRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
    }

    /// Removes the record, its folder and its downloaded asset.
    func delete(itemID: String) {
        guard let serverID, let userID else { return }

        if let record = record(for: itemID), let assetURL = assetURL(for: record) {
            try? FileManager.default.removeItem(at: assetURL)
        }
        try? FileManager.default.removeItem(at: Self.folder(serverID: serverID, userID: userID, itemID: itemID))
        records.removeAll { $0.id == itemID }
    }

    func assetURL(for record: DownloadRecord) -> URL? {
        guard let path = record.assetRelativePath else { return nil }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
    }

    func imageURL(for record: DownloadRecord, image: Image) -> URL {
        Self.folder(serverID: record.serverID, userID: record.userID, itemID: record.id)
            .appendingPathComponent("\(image.rawValue).jpg")
    }

    func reload(serverID: String?, userID: String?) {
        self.serverID = serverID
        self.userID = userID

        guard let serverID, let userID else {
            records = []
            return
        }

        let userFolder = Self.root.appendingPathComponent(serverID).appendingPathComponent(userID)
        let itemFolders = (try? FileManager.default.contentsOfDirectory(at: userFolder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        records = itemFolders
            .compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("record.json")) else { return nil }
                return try? decoder.decode(DownloadRecord.self, from: data)
            }
            .sorted { $0.downloadedAt < $1.downloadedAt }
    }

    private static func folder(serverID: String, userID: String, itemID: String) -> URL {
        root.appendingPathComponent(serverID).appendingPathComponent(userID).appendingPathComponent(itemID)
    }
}
