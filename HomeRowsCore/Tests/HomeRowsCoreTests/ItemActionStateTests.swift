//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
@testable import HomeRowsCore
import XCTest

private let saveOff =
    #"{"Id":"save","Label":"Save","Icon":"bookmark","Kind":"toggle","State":"off","Labels":{"on":"Saved","off":"Save"},"Enabled":true}"#
private let saveOn =
    #"{"Id":"save","Label":"Saved","Icon":"bookmark","Kind":"toggle","State":"on","Labels":{"on":"Saved","off":"Save"},"Enabled":true}"#
private let downloadLabels = #"{"available":"Download","requested":"Requested","downloading":"Downloading","failed":"Retry download"}"#
private func download(_ state: String, enabled: Bool) -> String {
    #"{"Id":"download","Label":"Download","Icon":"download","Kind":"request","State":"\#(state)","Labels":\#(downloadLabels),"Enabled":\#(enabled)}"#
}

private let watchTrailer = #"{"Id":"watch-trailer","Label":"Watch trailer","Icon":"trailer","Kind":"play-queue"}"#

private let labels = ["on": "Saved", "off": "Save"]

private func save(_ state: String) -> ItemAction {
    ItemAction(id: "save", label: "Save", icon: "bookmark", kind: "toggle", state: state, labels: labels, enabled: true)
}

final class ItemActionStateTests: XCTestCase {

    // MARK: Decoding

    func testDecodesStateLabelsEnabled() async {
        let transport = FakeTransport { _, _ in (200, "[\(saveOff),\(download("requested", enabled: false))]") }
        let actions = await ItemActionsAPI(transport: transport).actions(itemID: "abc")

        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0].state, "off")
        XCTAssertEqual(actions[0].labels, ["on": "Saved", "off": "Save"])
        XCTAssertTrue(actions[0].isEnabled)
        XCTAssertEqual(actions[1].kind, ItemActionKind.request)
        XCTAssertEqual(actions[1].state, "requested")
        XCTAssertFalse(actions[1].isEnabled)
        XCTAssertEqual(actions[1].labels["downloading"], "Downloading")
    }

    func testDecodesFailedDownloadAsEnabledRetry() async {
        let transport = FakeTransport { _, _ in (200, "[\(download("failed", enabled: true))]") }
        let actions = await ItemActionsAPI(transport: transport).actions(itemID: "abc")

        XCTAssertEqual(actions.first?.state, "failed")
        XCTAssertEqual(actions.first?.isEnabled, true)
        XCTAssertEqual(actions.first.flatMap(stateButton(for:))?.label, "Retry download")
        XCTAssertEqual(actions.first.flatMap(stateButton(for:))?.isEnabled, true)
    }

    func testOlderActionWithoutNewFieldsIsEnabledWithNoState() async {
        let transport = FakeTransport { _, _ in (200, "[\(watchTrailer)]") }
        let actions = await ItemActionsAPI(transport: transport).actions(itemID: "abc")

        XCTAssertNil(actions.first?.state)
        XCTAssertEqual(actions.first?.labels, [:])
        XCTAssertEqual(actions.first?.isEnabled, true)
    }

    // MARK: Perform

    func testPerformPostsAndReturnsAction() async throws {
        let transport = FakeTransport { _, _ in (200, saveOn) }
        let action = try await ItemActionsAPI(transport: transport).perform(itemID: "abc", actionID: "save")

        XCTAssertEqual(transport.calls.map(\.method), ["POST"])
        XCTAssertEqual(transport.calls.map(\.path), ["Items/abc/Actions/save"])
        XCTAssertEqual(action, ItemAction(id: "save", label: "Saved", icon: "bookmark", kind: "toggle", state: "on", labels: labels))
    }

    func testPerformThrowsOnAFailedStatus() async {
        let transport = FakeTransport { _, _ in (404, "") }
        do {
            _ = try await ItemActionsAPI(transport: transport).perform(itemID: "abc", actionID: "save")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? HomeRowsError, .status(404))
        }
    }

    func testPerformThrowsOnAnUnreadableAction() async {
        let transport = FakeTransport { _, _ in (200, #"{"Label":"No id"}"#) }
        do {
            _ = try await ItemActionsAPI(transport: transport).perform(itemID: "abc", actionID: "save")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? HomeRowsError, .invalidResponse)
        }
    }

    // MARK: Buttons

    func testToggleLabelByState() {
        XCTAssertEqual(stateButton(for: save("off"))?.label, "Save")
        XCTAssertEqual(stateButton(for: save("off"))?.systemImage, "bookmark")
        XCTAssertEqual(stateButton(for: save("off"))?.isOn, false)

        XCTAssertEqual(stateButton(for: save("on"))?.label, "Saved")
        XCTAssertEqual(stateButton(for: save("on"))?.systemImage, "bookmark.fill")
        XCTAssertEqual(stateButton(for: save("on"))?.isOn, true)
    }

    func testLabelFallsBackToActionLabelWithoutAStateLabel() {
        let action = ItemAction(id: "save", label: "Save", icon: "bookmark", kind: "toggle", state: "odd", labels: labels)
        XCTAssertEqual(stateButton(for: action)?.label, "Save")
    }

    func testRequestButtonLabelsAndEnabled() {
        let requested = ItemAction(
            id: "download", label: "Download", icon: "download", kind: "request",
            state: "requested", labels: ["available": "Download", "requested": "Requested"], enabled: false
        )
        let button = stateButton(for: requested)
        XCTAssertEqual(button?.label, "Requested")
        XCTAssertEqual(button?.systemImage, "clock")
        XCTAssertEqual(button?.isEnabled, false)
        XCTAssertEqual(button?.isOn, false)
    }

    func testPlayQueueAndUnknownKindsAreNotStateButtons() {
        XCTAssertNil(stateButton(for: ItemAction(id: "watch-trailer", label: "Watch trailer", icon: "trailer", kind: "play-queue")))
        XCTAssertNil(stateButton(for: ItemAction(id: "x", label: "X", icon: nil, kind: "teleport")))
    }

    func testIconMapping() {
        XCTAssertEqual(actionSystemImage(icon: "bookmark", isOn: false), "bookmark")
        XCTAssertEqual(actionSystemImage(icon: "bookmark", isOn: true), "bookmark.fill")
        XCTAssertEqual(actionSystemImage(icon: "download"), "arrow.down.circle")
        XCTAssertEqual(actionSystemImage(icon: "trailer"), "film")
        XCTAssertEqual(actionSystemImage(icon: "mystery"), "play.fill")
        XCTAssertEqual(actionSystemImage(icon: nil), "play.fill")
    }

    // MARK: Optimistic toggle

    func testOptimisticToggleFlipsStateAndLabel() {
        XCTAssertEqual(optimisticAction(save("off"))?.state, "on")
        XCTAssertEqual(optimisticAction(save("off")).flatMap(stateButton(for:))?.label, "Saved")
        XCTAssertEqual(optimisticAction(save("on"))?.state, "off")
    }

    func testRequestHasNoOptimisticGuess() {
        let available = ItemAction(id: "download", label: "Download", icon: "download", kind: "request", state: "available")
        XCTAssertNil(optimisticAction(available))
    }

    func testReplacingKeepsOrderAndOtherActions() {
        let download = ItemAction(id: "download", label: "Download", icon: "download", kind: "request", state: "available")
        let actions = [save("off"), download]
        XCTAssertEqual(replacingAction(save("on"), in: actions), [save("on"), download])
        // An action that isn't there leaves the list alone.
        let other = ItemAction(id: "other", label: "O", icon: nil, kind: "toggle")
        XCTAssertEqual(replacingAction(other, in: actions), actions)
    }

    // MARK: Item page row

    func testItemPageRowCarriesStateButtonsInServerOrder() {
        let download = ItemAction(id: "download", label: "Download", icon: "download", kind: "request", state: "available")
        let plan = actionButtons(
            actions: [ItemAction(id: "watch-trailer", label: "Watch trailer", icon: "trailer", kind: "play-queue"), save("off"), download],
            hasStockTrailers: false
        )
        XCTAssertEqual(plan.buttons.map(\.id), ["watch-trailer"])
        XCTAssertEqual(plan.stateButtons.map(\.id), ["save", "download"])
    }

    // MARK: Player

    func testPlayerActionsExcludePlayQueue() {
        let download = ItemAction(id: "download", label: "Download", icon: "download", kind: "request", state: "available")
        let actions = [
            ItemAction(id: "watch-trailer", label: "Watch trailer", icon: "trailer", kind: "play-queue"),
            save("off"),
            ItemAction(id: "x", label: "X", icon: nil, kind: "teleport"),
            download,
        ]
        let layout = playerActionLayout(actions: actions)
        XCTAssertEqual(layout.inline.map(\.id), ["save", "download"])
        XCTAssertEqual(layout.overflow, [])
    }

    func testPlayerActionsOverflowPastTwo() {
        let actions = ["a", "b", "c"].map {
            ItemAction(id: $0, label: $0, icon: "bookmark", kind: "toggle", state: "off", labels: labels)
        }
        let layout = playerActionLayout(actions: actions)
        XCTAssertEqual(layout.inline, [])
        XCTAssertEqual(layout.overflow.map(\.id), ["a", "b", "c"])
    }

    func testPlayerActionsOnAStockServerAreEmpty() {
        let layout = playerActionLayout(actions: [])
        XCTAssertEqual(layout.inline, [])
        XCTAssertEqual(layout.overflow, [])
    }

    // MARK: Request icons by state

    func testDownloadIconFollowsState() {
        XCTAssertEqual(actionSystemImage(icon: "download", state: ItemActionRequestState.available), "arrow.down.circle")
        XCTAssertEqual(actionSystemImage(icon: "download", state: ItemActionRequestState.failed), "arrow.down.circle")
        XCTAssertEqual(actionSystemImage(icon: "download", state: ItemActionRequestState.requested), "clock")
        XCTAssertEqual(actionSystemImage(icon: "download", state: ItemActionRequestState.downloading), "arrow.down.circle.dotted")
        XCTAssertEqual(actionSystemImage(icon: "download", state: nil), "arrow.down.circle")
    }

    func testRequestStateButtonUsesStateIcon() {
        let requested = ItemAction(
            id: "download",
            label: "Download",
            icon: "download",
            kind: "request",
            state: "requested",
            labels: [:],
            enabled: false
        )
        XCTAssertEqual(stateButton(for: requested)?.systemImage, "clock")
    }

    // MARK: Merging a refresh

    func testRefreshMergeKeepsPendingActions() {
        let current = [save("on"), downloadAction("requested")]
        let refreshed = [save("off"), downloadAction("downloading")]

        let merged = mergingRefreshedActions(refreshed, into: current, pendingIDs: ["save"])

        XCTAssertEqual(merged.map(\.id), ["save", "download"])
        XCTAssertEqual(merged[0].state, "on")
        XCTAssertEqual(merged[1].state, "downloading")
    }

    func testRefreshMergeWithNothingPendingTakesServer() {
        let refreshed = [save("on"), downloadAction("requested")]
        XCTAssertEqual(mergingRefreshedActions(refreshed, into: [save("off")], pendingIDs: []), refreshed)
    }

    func testRefreshMergePendingMissingFromCurrentTakesServer() {
        let refreshed = [save("on")]
        XCTAssertEqual(mergingRefreshedActions(refreshed, into: [], pendingIDs: ["save"]), refreshed)
    }

    // MARK: Pending by item

    func testPendingKeyIsPerItem() {
        let pending: Set<ItemActionPendingKey> = [ItemActionPendingKey(itemID: "a", actionID: "save")]
        XCTAssertTrue(pending.contains(ItemActionPendingKey(itemID: "a", actionID: "save")))
        XCTAssertFalse(pending.contains(ItemActionPendingKey(itemID: "b", actionID: "save")))
        XCTAssertEqual(pendingActionIDs(pending, itemID: "a"), ["save"])
        XCTAssertEqual(pendingActionIDs(pending, itemID: "b"), [])
        XCTAssertEqual(pendingActionIDs(pending, itemID: nil), [])
    }

    // MARK: Home rebuild

    func testHomeRefreshModeRebuildsWhenFlagged() {
        XCTAssertEqual(homeRefreshMode(needsRebuild: true, isStale: false, hasPendingSignals: false), .rebuild)
        XCTAssertEqual(homeRefreshMode(needsRebuild: true, isStale: true, hasPendingSignals: true), .rebuild)
        XCTAssertEqual(homeRefreshMode(needsRebuild: false, isStale: true, hasPendingSignals: false), .rowsOnly)
        XCTAssertEqual(homeRefreshMode(needsRebuild: false, isStale: false, hasPendingSignals: true), .rowsOnly)
        XCTAssertEqual(homeRefreshMode(needsRebuild: false, isStale: false, hasPendingSignals: false), .none)
    }
}

private func downloadAction(_ state: String) -> ItemAction {
    ItemAction(id: "download", label: "Download", icon: "download", kind: "request", state: state, labels: [:], enabled: true)
}
