//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

/// Press and hold to play faster; drag down while holding to lock the speed. Tap the pill, or press and hold again,
/// to unlock.
///
/// Methods that return a rate return the rate the player should switch to, or nil to leave it alone.
public struct SpeedHold: Sendable, Equatable {

    public enum State: Sendable, Equatable {
        case idle
        case holding
        case locked
        /// The press that unlocked is still down; its drag and release do nothing.
        case unlocking
    }

    public private(set) var state: State = .idle
    public let holdRate: Float
    /// How far down, in points, the finger must move while holding to lock.
    public let lockDistance: Double

    private var rateBeforeHold: Float = 1

    public init(holdRate: Float, lockDistance: Double = 60) {
        self.holdRate = holdRate
        self.lockDistance = lockDistance
    }

    public mutating func pressBegan(currentRate: Float) -> Float? {
        if state == .locked {
            state = .unlocking
            return rateBeforeHold
        }
        guard state == .idle else { return nil }
        rateBeforeHold = currentRate
        state = .holding
        return holdRate
    }

    /// - Parameter downBy: the finger's downward travel since the press began; negative is up.
    public mutating func dragged(downBy: Double) {
        guard state == .holding, downBy > lockDistance else { return }
        state = .locked
    }

    public mutating func pressEnded() -> Float? {
        if state == .unlocking {
            state = .idle
            return nil
        }
        guard state == .holding else { return nil }
        state = .idle
        return rateBeforeHold
    }

    public mutating func tapPill() -> Float? {
        guard state == .locked else { return nil }
        state = .idle
        return rateBeforeHold
    }
}
