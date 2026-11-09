//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation
import HomeRowsCore
import JellyfinAPI

@MainActor
@Stateful
final class ContentGroupViewModel<Provider: ContentGroupProvider>: ViewModel {

    @CasePathable
    enum Action {
        case refresh

        var transition: Transition {
            .to(.refreshing, then: .content)
                .whenBackground(.refreshing)
        }
    }

    enum BackgroundState {
        case refreshing
    }

    enum State {
        case content
        case error
        case initial
        case refreshing
    }

    @Published
    private(set) var groups: [any ContentGroup] = []

    private var candidateGroups: [any ContentGroup] = []
    private var lastRefreshDate = Date.distantPast
    private var lastRefreshSignalDate = Date.distantPast
    /// Personal fork: Home's layout must be reloaded the next time it appears (a Save or Download changed a row).
    private var needsRebuild = false

    private var hasPendingRefreshSignals: Bool {
        lastRefreshSignalDate > lastRefreshDate
    }

    var provider: Provider

    init(provider: Provider) {
        self.provider = provider
        super.init()

        Publishers.Merge(
            Notifications[.itemUserDataDidChange].publisher.map { _ in () },
            Notifications[.itemMetadataDidChange].publisher.map { _ in () }
        )
        .sink { [weak self] _ in
            self?.lastRefreshSignalDate = Date.now
        }
        .store(in: &cancellables)

        // Personal fork: reload after the home rows layout changes, see Objects/HomeRows
        Notifications[.homeRowsDidChange].publisher
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // Personal fork: a Save or Download marks Home for a full rebuild when it next appears, not behind the player.
        if Provider.self == DefaultContentGroupProvider.self {
            Notifications[.homeRowsNeedRebuild].publisher
                .sink { [weak self] _ in self?.needsRebuild = true }
                .store(in: &cancellables)
        }
    }

    func refreshIfNeeded(
        sinceLastDisappear interval: TimeInterval,
        staleThreshold: TimeInterval = 60
    ) {
        switch homeRefreshMode(
            needsRebuild: needsRebuild,
            isStale: interval > staleThreshold,
            hasPendingSignals: hasPendingRefreshSignals
        ) {
        case .rebuild:
            refresh()
        case .rowsOnly:
            background.refresh()
        case .none:
            break
        }
    }

    func refreshIfPendingChanges() {
        guard needsRebuild || hasPendingRefreshSignals else { return }

        refresh()
    }

    @Function(\Action.Cases.refresh)
    private func _refresh() async throws {
        if StateTask.isBackground {
            try await backgroundRefresh()
        } else {
            try await fullRefresh()
        }

        lastRefreshDate = Date.now
    }

    private func getViewModel(for group: some ContentGroup) -> any WithRefresh {
        group.viewModel
    }

    private func resolveGroups() {
        groups = candidateGroups
            .filter(\._shouldBeResolved)
    }

    private func refreshViewModels(
        for groups: [any ContentGroup],
        inBackground: Bool
    ) async throws {
        let viewModels = groups.map { getViewModel(for: $0) }
            .uniqued { ObjectIdentifier($0 as AnyObject) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for viewModel in viewModels {
                group.addTask {
                    if inBackground {
                        await viewModel.background.refresh()
                    } else {
                        await viewModel.refresh()
                    }
                }
            }

            try await group.waitForAll()
        }
    }

    private func backgroundRefresh() async throws {
        try await refreshViewModels(
            for: candidateGroups,
            inBackground: true
        )

        resolveGroups()
    }

    private func fullRefresh() async throws {

        needsRebuild = false
        self.groups = []
        self.candidateGroups = []

        let newGroups = try await provider.makeGroups(environment: provider.environment)

        try await refreshViewModels(
            for: newGroups,
            inBackground: false
        )

        candidateGroups = newGroups
        resolveGroups()
    }
}
