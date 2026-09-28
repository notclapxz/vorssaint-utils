// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// How far the script has scrolled, kept free of AppKit so the harness can
/// check it. Speed is a level rather than points per second: twenty steps are
/// what the arrow keys walk through, and a level reads the same at any size.
enum TeleprompterSupport {
    static let speedRange = 1...20
    static let defaultSpeed = 8
    /// The slowest level is roughly a line every six seconds at the reading
    /// size: ten levels of twice this proved too fast at the bottom.
    static let pointsPerSecondPerLevel = 6.0

    static func sanitizedSpeed(_ speed: Int) -> Int {
        min(speedRange.upperBound, max(speedRange.lowerBound, speed))
    }

    /// The offset after `elapsed` seconds of playing. Paused time is simply
    /// never passed in, so a pause freezes the text where it was. It stops at
    /// `limit`, the point where the last line has reached the reading area.
    static func advanced(offset: Double, elapsed: Double, speed: Int, limit: Double) -> Double {
        let ceiling = max(0, limit.isFinite ? limit : 0)
        let start = min(ceiling, max(0, offset.isFinite ? offset : 0))
        guard elapsed.isFinite, elapsed > 0 else { return start }
        let step = elapsed * Double(sanitizedSpeed(speed)) * pointsPerSecondPerLevel
        return min(ceiling, start + step)
    }
}
