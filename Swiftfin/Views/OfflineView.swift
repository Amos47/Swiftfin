//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import SwiftUI

/// Personal fork: shown over Home while the server can't be reached.
struct HomeOfflineOverlay: View {

    @ObservedObject
    private var reachability = Container.shared.serverReachability()

    var body: some View {
        ZStack {
            if !reachability.isReachable {
                OfflineView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: reachability.isReachable)
    }
}

struct OfflineView: View {

    @Router
    private var router

    @ObservedObject
    private var reachability = Container.shared.serverReachability()
    @ObservedObject
    private var downloads = Container.shared.downloadStore()

    @State
    private var isChecking = false

    private var serverName: String {
        Container.shared.currentUserSession()?.server.name ?? ""
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.secondary)

            Text(L10n.youreOffline)
                .font(.title2.weight(.bold))

            Text(L10n.offlineMessage(serverName))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                if downloads.records.contains(where: \.isComplete) {
                    Button {
                        router.route(to: .downloads)
                    } label: {
                        Text(L10n.goToDownloads)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.jellyfinPurple)
                    .controlSize(.large)
                }

                Button {
                    Task {
                        isChecking = true
                        await reachability.check()
                        isChecking = false
                    }
                } label: {
                    Group {
                        if isChecking {
                            ProgressView()
                        } else {
                            Text(L10n.tryAgain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isChecking)
            }
            .frame(maxWidth: 320)
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
