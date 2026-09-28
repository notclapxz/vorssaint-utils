// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

/// Export size and frame rate, chosen per export and remembered.
///
/// Exporting is bound by the Mac's single hardware encoder, which runs at a
/// fixed number of pixels per second: measured on an M5 at 3024×1964 and
/// 60 fps, the editor's full export (18.9 s for 30 s of video) is within 5% of
/// a bare re-encode (18.05 s), and two encodes at once take twice as long.
/// No code change can make it faster; fewer pixels or fewer frames can.
///
/// The size is one factor applied to the whole canvas, width and height
/// alike, so whatever was recorded (a window, an area, a screen) keeps its
/// shape and never gains bars.
enum RecorderExportOptions {
    /// Longest side of the finished picture; 0 keeps the recording's own.
    static let longSides = [0, 1920, 1280]
    /// 0 keeps the recording's own rate.
    static let frameRateCaps = [0, 30]

    static func sanitizedLongSide(_ value: Int) -> Int {
        longSides.contains(value) ? value : 0
    }

    static func sanitizedFrameRateCap(_ value: Int) -> Int {
        frameRateCaps.contains(value) ? value : 0
    }

    /// The factor applied to the canvas. A smaller quality preset already
    /// shrinks it; a size choice only ever shrinks further, never back up.
    static func scale(canvas: CGSize, qualityScale: CGFloat, longSide: Int) -> CGFloat {
        let base = qualityScale.isFinite && qualityScale > 0 ? min(1, qualityScale) : 1
        let longest = max(canvas.width, canvas.height)
        guard sanitizedLongSide(longSide) > 0, longest > 0 else { return base }
        return min(base, CGFloat(longSide) / longest)
    }

    /// The sizes worth offering for this recording: its own, and each smaller
    /// one it is actually bigger than. A window already under 1280 wide
    /// offers nothing but its own size.
    static func offeredLongSides(canvas: CGSize, qualityScale: CGFloat) -> [Int] {
        let longest = max(canvas.width, canvas.height) * scale(canvas: canvas,
                                                               qualityScale: qualityScale,
                                                               longSide: 0)
        return longSides.filter { $0 == 0 || CGFloat($0) < longest }
    }

    static func frameRate(source: Int, cap: Int) -> Int {
        let capped = sanitizedFrameRateCap(cap)
        return capped > 0 ? min(source, capped) : source
    }

    static func outputSize(canvas: CGSize, scale: CGFloat) -> CGSize {
        RecorderSupport.evenSize(CGSize(width: canvas.width * scale, height: canvas.height * scale))
    }

    static var storedLongSide: Int {
        sanitizedLongSide(UserDefaults.standard.integer(forKey: DefaultsKey.recorderExportLongSide))
    }

    static var storedFrameRateCap: Int {
        sanitizedFrameRateCap(UserDefaults.standard.integer(forKey: DefaultsKey.recorderExportFrameRateCap))
    }
}
