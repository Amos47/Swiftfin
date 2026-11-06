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

/// Personal fork: an episode row's download button. An arrow (tap downloads straight away), then a progress ring
/// (tap to cancel), then a check with Play and Delete.
struct DownloadButton: View {

    @Router
    private var router

    @ObservedObject
    private var store = Container.shared.downloadStore()

    let item: BaseItemDto

    private var service: DownloadService {
        Container.shared.downloadService()
    }

    var body: some View {
        Group {
            switch store.record(for: item.id)?.state {
            case .none:
                Button {
                    Task {
                        try? await service.download(item)
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Color.jellyfinPurple)
                }
            case .queued, .waiting:
                Button(action: cancel) {
                    DownloadProgressRing(progress: 0)
                }
            case let .downloading(progress):
                Button(action: cancel) {
                    DownloadProgressRing(progress: progress)
                }
            case .complete:
                Menu {
                    Button(L10n.play, systemImage: "play.fill") {
                        item.play(router: router)
                    }
                    Button(L10n.delete, systemImage: "trash", role: .destructive, action: cancel)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.jellyfinPurple)
                }
            case .failed:
                Menu {
                    Button(L10n.retry, systemImage: "arrow.clockwise") {
                        if let id = item.id {
                            service.retry(itemID: id)
                        }
                    }
                    Button(L10n.delete, systemImage: "trash", role: .destructive, action: cancel)
                } label: {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
            }
        }
        .font(.title2)
        .frame(width: 40, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(L10n.download)
    }

    private func cancel() {
        guard let id = item.id else { return }
        service.cancelOrDelete(itemID: id)
    }
}

struct DownloadProgressRing: View {

    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.03, progress))
                .stroke(Color.jellyfinPurple, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "stop.fill")
                .font(.system(size: 7))
                .foregroundStyle(Color.jellyfinPurple)
        }
        .frame(width: 26, height: 26)
        .animation(.linear(duration: 0.3), value: progress)
    }
}

enum DownloadSizes {

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
