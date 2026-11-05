//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import PlayerCore
import SwiftUI

// TODO: multitap refinements
//       - don't increment jump progress if hit ends
//       - verify if ending media

extension VideoPlayer.UIVideoPlayerContainerViewController {

    func checkGestureLock() -> Bool {
        if containerState.isGestureLocked {
            containerState.toastProxy.present(
                L10n.pressAndHoldToUnlock,
                systemName: VideoPlayerActionButton.gestureLock.systemImage
            )
            return false
        }
        return true
    }

    func handleTapGestureInSupplement(
        location: CGPoint,
        unitPoint: UnitPoint,
        count: Int
    ) {
        guard !containerState.isPresentingSupplement else { return }

        handleTapGesture(
            location: location,
            unitPoint: unitPoint,
            count: count
        )
    }

    func handleTapGesture(
        location: CGPoint,
        unitPoint: UnitPoint,
        count: Int
    ) {
        if count == 1 {
            guard checkGestureLock() else { return }

            handleSingleTapGesture(
                location: location,
                unitPoint: unitPoint
            )
        }

        if count == 2 {
            handleDoubleTouchGesture(
                location: location,
                unitPoint: unitPoint
            )
        }
    }

    private func handleSingleTapGesture(
        location: CGPoint,
        unitPoint: UnitPoint
    ) {
        if containerState.isPresentingSupplement {
            if containerState.isCompact {
                containerState.isPresentingPlaybackControls.toggle()
            } else {
                containerState.select(supplement: nil)
            }
        } else {
            containerState.isPresentingOverlay.toggle()
        }

        let action = Defaults[.VideoPlayer.Gesture.multiTapGesture]
        let jumpProgressObserver = containerState.jumpProgressObserver
        let width = location.x / unitPoint.x

        switch action {
        case .none: ()
        case .jump:
            guard containerState.manager?.item.isLiveStream == false else { return }

            if let lastTapLocation = containerState.lastTapLocation {

                let (isSameSide, isLeftSide) = pointsAreSameSide(
                    lastTapLocation,
                    location,
                    width: width,
                    midPadding: containerState.isCompact ? 20 : 50
                )

                if isSameSide {

                    containerState.isPresentingOverlay = false

                    if isLeftSide {
                        let interval = Defaults[.VideoPlayer.jumpBackwardInterval]
                        containerState.manager?.proxy?.jumpBackward(interval.rawValue)

                        containerState.toastProxy.present(
                            Text(
                                interval.rawValue * (jumpProgressObserver.jumps),
                                format: .minuteSecondsNarrow
                            ),
                            systemName: "gobackward"
                        )
                    } else {
                        let interval = Defaults[.VideoPlayer.jumpForwardInterval]
                        containerState.manager?.proxy?.jumpForward(interval.rawValue)

                        containerState.toastProxy.present(
                            Text(
                                interval.rawValue * (jumpProgressObserver.jumps),
                                format: .minuteSecondsNarrow
                            ),
                            systemName: "goforward"
                        )
                    }
                }
            }
        }

        let side = side(
            of: location,
            width: width,
            midPadding: containerState.isCompact ? 20 : 50
        )
        containerState.lastTapLocation = location

        if side {
            jumpProgressObserver.jumpBackward(interval: 0.35)
        } else {
            jumpProgressObserver.jumpForward(interval: 0.35)
        }
    }

    private func side(
        of point: CGPoint,
        width: CGFloat,
        midPadding: CGFloat = 50
    ) -> Bool {
        let midX = width / 2
        let leftSide = midX - midPadding

        return point.x < leftSide
    }

    private func pointsAreSameSide(
        _ p1: CGPoint,
        _ p2: CGPoint,
        width: CGFloat,
        midPadding: CGFloat = 50
    ) -> (isSameSide: Bool, isLeftSide: Bool) {
        let p1Side = side(of: p1, width: width, midPadding: midPadding)
        let p2Side = side(of: p2, width: width, midPadding: midPadding)

        return (p1Side == p2Side, p1Side)
    }

    private func handleDoubleTouchGesture(
        location: CGPoint,
        unitPoint: UnitPoint
    ) {
        let action = Defaults[.VideoPlayer.Gesture.doubleTouchGesture]

        switch action {
        case .none: ()
        case .aspectFill:
            guard checkGestureLock() else { return }
            containerState.isAspectFilled.toggle()
        case .gestureLock:
            if containerState.isGestureLocked {
                containerState.isGestureLocked = false

                containerState.toastProxy.present(
                    L10n.gesturesUnlocked,
                    systemName: VideoPlayerActionButton.gestureLock.secondarySystemImage
                )
            } else {
                containerState.isGestureLocked = true

                containerState.toastProxy.present(
                    L10n.gesturesLocked,
                    systemName: VideoPlayerActionButton.gestureLock.systemImage
                )
            }
        case .pausePlay:
            guard checkGestureLock() else { return }
            containerState.manager?.togglePlayPause()
        }
    }

    func handleLongPressGesture(
        location: CGPoint,
        unitPoint: UnitPoint,
        state: UILongPressGestureRecognizer.State
    ) {
        guard !containerState.isGestureLocked else {
            guard state == .began else { return }

            containerState.isGestureLocked = false

            containerState.toastProxy.present(
                L10n.gesturesUnlocked,
                systemName: VideoPlayerActionButton.gestureLock.secondarySystemImage
            )
            return
        }

        let action = Defaults[.VideoPlayer.Gesture.longPressAction]

        switch action {
        case .none: ()
        case .gestureLock:
            guard state == .began else { return }

            containerState.isGestureLocked = true

            containerState.toastProxy.present(
                L10n.gesturesLocked,
                systemName: VideoPlayerActionButton.gestureLock.systemImage
            )
        case .playbackSpeed:
            // Personal fork: hold for speed, drag down while holding to lock it; the speed pill shows the state.
            guard let manager = containerState.manager, manager.item.isLiveStream == false else { return }

            let holdRate = Defaults[.VideoPlayer.Gesture.longPressSpeedMultiplier].rawValue

            switch state {
            case .began:
                var hold = containerState.speedHold ?? SpeedHold(holdRate: holdRate)
                if hold.state == .idle, hold.holdRate != holdRate {
                    hold = SpeedHold(holdRate: holdRate)
                }
                if let rate = hold.pressBegan(currentRate: manager.rate) {
                    // Holding while locked unlocks, back to the saved speed.
                    manager.isTemporaryRate = hold.state == .holding
                    manager.setRate(rate: rate)
                }
                containerState.speedHold = hold
                containerState.speedHoldStart = location
            case .changed:
                guard var hold = containerState.speedHold, let start = containerState.speedHoldStart else { return }
                hold.dragged(downBy: location.y - start.y)
                if hold != containerState.speedHold {
                    containerState.speedHold = hold
                }
            case .ended, .cancelled, .failed:
                guard var hold = containerState.speedHold else { return }
                if let rate = hold.pressEnded() {
                    manager.isTemporaryRate = false
                    manager.setRate(rate: rate)
                }
                containerState.speedHold = hold
                containerState.speedHoldStart = nil
            default:
                break
            }
        }
    }
}
