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

/// Personal fork: an episode row's download button. An arrow, then a progress ring (tap to cancel), then a check with
/// Play and Delete.
struct DownloadButton: View {

    @Router
    private var router

    @ObservedObject
    private var store = Container.shared.downloadStore()

    @State
    private var estimate: (bytes: Int64, freeBytes: Int64)?
    @State
    private var isConfirming = false

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
                        estimate = await service.estimate(for: item)
                        isConfirming = true
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                }
            case .queued:
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
        .font(.body)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .accessibilityLabel(L10n.download)
        .confirmationDialog(L10n.download, isPresented: $isConfirming, titleVisibility: .visible) {
            Button(L10n.download) {
                Task {
                    try? await service.download(item)
                }
            }
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            if let estimate {
                Text(DownloadSizes.confirmation(bytes: estimate.bytes, freeBytes: estimate.freeBytes))
            }
        }
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
        .frame(width: 20, height: 20)
        .animation(.linear(duration: 0.3), value: progress)
    }
}

enum DownloadSizes {

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "About 250 MB · 15 GB free", with a warning when it may not fit.
    static func confirmation(bytes: Int64, freeBytes: Int64) -> String {
        let line = L10n.downloadEstimate(format(bytes), format(freeBytes))
        return bytes > freeBytes ? "\(line)\n\(L10n.downloadMayNotFit)" : line
    }
}
