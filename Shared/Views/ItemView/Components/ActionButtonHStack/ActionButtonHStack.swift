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

extension ItemView {

    struct ActionButtonHStack: View {

        @ObservedObject
        var provider: ItemContentGroupProvider

        @Router
        private var router

        @StoredValue(.User.enabledTrailers)
        private var enabledTrailers: TrailerSelection

        #if os(iOS)
        // Personal fork: download controls for episodes and movies.
        @ObservedObject
        private var downloadStore = Container.shared.downloadStore()

        private var canDownload: Bool {
            provider.item.id != nil && !provider.item.isMissing && (provider.item.type == .episode || provider.item.type == .movie)
        }
        #endif

        // Personal fork: the server's item actions (Watch trailer).
        @State
        private var runningActionID: String?
        @State
        private var actionError: Error?

        /// The server's answer for this item, or nil while it's still coming.
        private var serverActions: ServerItemActions? {
            guard let answer = provider.serverActions, answer.itemID == provider.item.id else { return nil }
            return answer
        }

        private var actionPlan: ItemActionPlan {
            actionButtons(actions: serverActions?.actions ?? [], hasStockTrailers: hasTrailers)
        }

        /// The stock Trailers button waits for the server's answer, so Watch trailer replaces it instead of swapping in.
        private var showsStockTrailers: Bool {
            serverActions != nil && actionPlan.showStockTrailers
        }

        private var hasTrailers: Bool {
            if enabledTrailers.contains(.local), provider.localTrailers.isNotEmpty {
                return true
            }

            if enabledTrailers.contains(.external), provider.item.remoteTrailers?.isNotEmpty == true {
                return true
            }

            return false
        }

        @ViewBuilder
        private func materialLabel(
            _ title: String,
            systemImage: String,
            isHighlighted: Bool = false,
            tint: Color,
            foregroundColor: Color,
            isRotated: Bool = false
        ) -> some View {
            #if os(tvOS)
            let shape: Rectangle = .rect
            #else
            let shape: RoundedRectangle = .rect(cornerRadius: 10, style: .circular)
            #endif

            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .rotationEffect(isRotated ? .degrees(90) : .degrees(0))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .backport
            .glassEffect(
                .regular.selection(
                    tint: isHighlighted ? tint : .gray.opacity(0.3),
                    foregroundColor: foregroundColor
                ),
                in: shape
            )
        }

        var body: some View {
            if (UIDevice.isTV && provider.item.canEdit) ||
                provider.item.canBePlayed ||
                provider.item.canBeFavorited ||
                hasTrailers ||
                actionPlan.buttons.isNotEmpty
            {
                contentView
                    .errorMessage($actionError)
            }
        }

        private var contentView: some View {
            HStack(alignment: .center, spacing: UIDevice.isTV ? 30 : 10) {

                // MARK: Played

                if provider.item.canBePlayed {
                    let isPlayed = provider.item.userData?.isPlayed == true

                    Button {
                        Task { await provider.toggleIsPlayed() }
                    } label: {
                        materialLabel(
                            L10n.played,
                            systemImage: "checkmark",
                            isHighlighted: isPlayed,
                            tint: .jellyfinPurple,
                            foregroundColor: .primary
                        )
                    }
                    #if !os(tvOS)
                    .foregroundStyle(.primary, .secondary)
                    #endif
                }

                // MARK: Favorite

                if provider.item.canBeFavorited {
                    let isFavorited = provider.item.userData?.isFavorite == true

                    Button {
                        Task { await provider.toggleIsFavorite() }
                    } label: {
                        materialLabel(
                            L10n.favorited,
                            systemImage: isFavorited ? "heart.fill" : "heart",
                            isHighlighted: isFavorited,
                            tint: .pink,
                            foregroundColor: .primary
                        )
                    }
                    #if !os(tvOS)
                    .foregroundStyle(.primary, .secondary)
                    #endif
                    .isSelected(isFavorited)
                }

                // MARK: Download

                #if os(iOS)
                if canDownload {
                    downloadButton
                }
                #endif

                // MARK: Server actions

                ForEach(actionPlan.buttons) { action in
                    Button {
                        play(action)
                    } label: {
                        materialLabel(
                            action.label,
                            systemImage: action.systemImage,
                            tint: .pink,
                            foregroundColor: .primary
                        )
                    }
                    .foregroundStyle(.primary, .secondary)
                }

                // MARK: Trailer

                if showsStockTrailers {
                    TrailerMenu(
                        localTrailers: provider.localTrailers,
                        externalTrailers: provider.item.remoteTrailers ?? []
                    ) {
                        materialLabel(
                            L10n.trailers,
                            systemImage: "movieclapper",
                            tint: .pink,
                            foregroundColor: .primary
                        )
                    }
                }

                // MARK: tvOS Options

                #if os(tvOS)
                if provider.item.canEdit || provider.item.canDeleteItem {
                    EditItemMenu(item: provider.item) {
                        materialLabel(
                            L10n.advanced,
                            systemImage: "ellipsis",
                            tint: .clear,
                            foregroundColor: .primary,
                            isRotated: true
                        )
                    }
                    .frame(width: 60)
                    .foregroundStyle(.primary, .secondary)
                }
                #endif
            }
            .frame(height: UIDevice.isTV ? 75 : 44)
            .labelStyle(.iconOnly)
            .buttonStyle(BasicHoverButtonStyle())
            .font(.title3)
            .fontWeight(.semibold)
        }

        /// Personal fork: plays a server action's queue. Taps while one is loading are ignored.
        private func play(_ action: ItemActionButton) {
            guard runningActionID == nil,
                  let itemID = provider.item.id,
                  let session = Container.shared.currentUserSession()
            else { return }

            runningActionID = action.id
            Task {
                defer { runningActionID = nil }
                do {
                    let playback = try await ItemActionPlayback.playback(itemID: itemID, action: action, session: session)
                    router.route(to: .videoPlayer(provider: playback.provider, queue: playback.queue))
                } catch {
                    provider.logger.error("Unable to play item action \(action.id): \(error.localizedDescription)")
                    actionError = ErrorMessage(action.id == ItemActionID.watchTrailer ? L10n.unableToOpenTrailer : L10n.unknownError)
                }
            }
        }

        #if os(iOS)
        /// Download (an arrow), a progress ring while downloading (tap to cancel), a filled check once downloaded
        /// (tap: Delete download), and Retry or Delete after a failure.
        @ViewBuilder
        private var downloadButton: some View {
            let item = provider.item
            let itemID = item.id ?? ""
            let service = Container.shared.downloadService()

            switch downloadStore.record(for: itemID)?.state {
            case .none:
                Button {
                    Task { try? await service.download(item) }
                } label: {
                    materialLabel(L10n.download, systemImage: "arrow.down.circle", tint: .jellyfinPurple, foregroundColor: .primary)
                }
                .foregroundStyle(.primary, .secondary)
            case .queued, .waiting:
                Button {
                    service.cancelOrDelete(itemID: itemID)
                } label: {
                    progressLabel(progress: 0)
                }
            case let .downloading(progress):
                Button {
                    service.cancelOrDelete(itemID: itemID)
                } label: {
                    progressLabel(progress: progress)
                }
            case .complete:
                Menu {
                    Button(L10n.deleteDownload, systemImage: "trash", role: .destructive) {
                        service.cancelOrDelete(itemID: itemID)
                    }
                } label: {
                    materialLabel(
                        L10n.downloaded,
                        systemImage: "arrow.down.circle.fill",
                        isHighlighted: true,
                        tint: .jellyfinPurple,
                        foregroundColor: .primary
                    )
                }
            case .failed:
                Menu {
                    Button(L10n.retry, systemImage: "arrow.clockwise") {
                        service.retry(itemID: itemID)
                    }
                    Button(L10n.deleteDownload, systemImage: "trash", role: .destructive) {
                        service.cancelOrDelete(itemID: itemID)
                    }
                } label: {
                    materialLabel(L10n.download, systemImage: "exclamationmark.circle", tint: .red, foregroundColor: .red)
                }
            }
        }

        private func progressLabel(progress: Double) -> some View {
            DownloadProgressRing(progress: progress)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .backport
                .glassEffect(
                    .regular.selection(tint: .gray.opacity(0.3), foregroundColor: .primary),
                    in: .rect(cornerRadius: 10, style: .circular)
                )
                .accessibilityLabel(L10n.download)
        }
        #endif
    }
}
