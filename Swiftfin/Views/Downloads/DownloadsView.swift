//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import JellyfinAPI
import SwiftUI

extension NavigationRoute {

    /// Personal fork: the current user's downloads.
    static var downloads: NavigationRoute {
        NavigationRoute(id: "downloads") {
            DownloadsView()
        }
    }
}

/// Personal fork: downloads grouped by show, movies last. Tapping a finished one plays it from the file.
struct DownloadsView: View {

    @Router
    private var router

    @ObservedObject
    private var store = Container.shared.downloadStore()

    private struct Group: Identifiable {
        let id: String
        let title: String
        let records: [DownloadRecord]
    }

    private var groups: [Group] {
        let episodes = Dictionary(grouping: store.records.filter { $0.item.type == .episode }) { $0.item.seriesID ?? "" }
        let shows = episodes
            .map { seriesID, records in
                Group(
                    id: seriesID,
                    title: records.first?.item.seriesName ?? "",
                    records: records.sorted {
                        ($0.item.parentIndexNumber ?? 0, $0.item.indexNumber ?? 0) <
                            ($1.item.parentIndexNumber ?? 0, $1.item.indexNumber ?? 0)
                    }
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let movies = store.records.filter { $0.item.type != .episode }
        return movies.isEmpty ? shows : shows + [Group(id: "movies", title: L10n.movies, records: movies)]
    }

    private var totalBytes: Int64 {
        store.records.map(\.estimatedBytes).reduce(0, +)
    }

    var body: some View {
        List {
            if store.records.isEmpty {
                Text(L10n.noDownloads)
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    EmptyView()
                } footer: {
                    Text(L10n.downloadSpaceUsed(DownloadSizes.format(totalBytes)))
                }

                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.records) { record in
                            DownloadRow(record: record) {
                                record.item.play(router: router)
                            }
                            .swipeActions {
                                Button(L10n.delete, systemImage: "trash", role: .destructive) {
                                    Container.shared.downloadService().cancelOrDelete(itemID: record.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.downloads)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DownloadRow: View {

    let record: DownloadRecord
    let play: () -> Void

    private var store: DownloadStore {
        Container.shared.downloadStore()
    }

    private var title: String {
        let item = record.item
        if item.type == .episode, let episode = item.indexNumber {
            return "\(item.parentIndexNumber.map { "S\($0):" } ?? "")E\(episode) · \(item.displayTitle)"
        }
        return item.displayTitle
    }

    var body: some View {
        Button {
            if record.isComplete {
                play()
            }
        } label: {
            HStack(spacing: 12) {
                thumbnail

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    status
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var thumbnail: some View {
        Group {
            if let image = UIImage(contentsOfFile: store.imageURL(for: record, image: .thumb).path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var status: some View {
        switch record.state {
        case .queued:
            Text(L10n.downloadWaiting)
        case .waiting:
            Text(L10n.downloadWaitingForServer)
        case let .downloading(progress):
            ProgressView(value: progress)
                .tint(Color.jellyfinPurple)
        case .complete:
            Text(verbatim: DownloadSizes.format(record.estimatedBytes))
        case let .failed(message):
            HStack {
                Text(message)
                    .lineLimit(1)
                Button(L10n.retry) {
                    Container.shared.downloadService().retry(itemID: record.id)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

/// Personal fork: opens Downloads from the Media tab; shown when there are downloads. When the app starts without
/// reaching the server, it opens Downloads by itself (`DownloadsLaunch`).
struct DownloadsToolbarButton: View {

    @Router
    private var router

    @ObservedObject
    private var store = Container.shared.downloadStore()
    @ObservedObject
    private var launch = DownloadsLaunch.shared

    var body: some View {
        if store.records.isNotEmpty {
            Button(L10n.downloads, systemImage: "arrow.down.circle") {
                router.route(to: .downloads)
            }
            .onAppear(perform: openIfRequested)
            .onChange(of: launch.shouldOpenDownloads) {
                openIfRequested()
            }
        }
    }

    private func openIfRequested() {
        guard launch.shouldOpenDownloads else { return }
        launch.shouldOpenDownloads = false
        router.route(to: .downloads)
    }
}

/// Personal fork: at launch, checks the server once; with no server and some downloads, the app opens on Downloads.
@MainActor
final class DownloadsLaunch: ObservableObject {

    static let shared = DownloadsLaunch()

    @Published
    var shouldOpenDownloads = false

    private var hasChecked = false

    /// Returns true when the app should switch to the Media tab to show Downloads.
    func checkServer() async -> Bool {
        guard !hasChecked else { return false }
        hasChecked = true

        guard Container.shared.downloadStore().records.contains(where: \.isComplete),
              let client = Container.shared.currentUserSession()?.client
        else { return false }

        var request = URLRequest(url: client.configuration.url.appendingPathComponent("System/Ping"))
        request.timeoutInterval = 3
        if await (try? URLSession.shared.data(for: request)) != nil {
            return false
        }

        shouldOpenDownloads = true
        return true
    }
}

/// Personal fork: on error screens, a way to the downloads when the server can't be reached.
struct GoToDownloadsButton: View {

    @Router
    private var router

    @ObservedObject
    private var store = Container.shared.downloadStore()

    var body: some View {
        if store.records.contains(where: \.isComplete) {
            Button(L10n.goToDownloads) {
                router.route(to: .downloads)
            }
            .fontWeight(.semibold)
        }
    }
}
