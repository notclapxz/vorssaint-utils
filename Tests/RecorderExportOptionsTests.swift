// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

enum RecorderExportOptionsTests {
    static func run(_ suite: TestSuite) {
        let screen = CGSize(width: 3024, height: 1964)
        let at1080 = RecorderExportOptions.outputSize(
            canvas: screen,
            scale: RecorderExportOptions.scale(canvas: screen, qualityScale: 1, longSide: 1920))
        suite.expect(at1080.width == 1920 && abs(at1080.height - 1247) <= 1
                && Int(at1080.width) % 2 == 0 && Int(at1080.height) % 2 == 0,
               "1080p fits the long side and keeps the recording's shape, in even pixels")
        let tall = CGSize(width: 900, height: 1600)
        suite.expect(RecorderExportOptions.outputSize(
                    canvas: tall,
                    scale: RecorderExportOptions.scale(canvas: tall, qualityScale: 1, longSide: 1280)).height == 1280,
               "a tall window is fitted by its height, so it never gains bars")
        suite.expect(RecorderExportOptions.offeredLongSides(canvas: CGSize(width: 1400, height: 900), qualityScale: 1)
                == [0, 1280]
                && RecorderExportOptions.offeredLongSides(canvas: CGSize(width: 1100, height: 700), qualityScale: 1)
                == [0],
               "only sizes smaller than what was recorded are offered")
        suite.expect(RecorderExportOptions.scale(canvas: screen, qualityScale: 0.5, longSide: 1920) == 0.5
                && RecorderExportOptions.scale(canvas: screen, qualityScale: 1, longSide: 777) == 1,
               "a size choice never enlarges a smaller preset, and an unknown one keeps the original")
        suite.expect(RecorderExportOptions.frameRate(source: 60, cap: 30) == 30
                && RecorderExportOptions.frameRate(source: 24, cap: 30) == 24
                && RecorderExportOptions.frameRate(source: 60, cap: 0) == 60
                && RecorderExportOptions.frameRate(source: 60, cap: 45) == 60,
               "the frame rate cap only ever lowers the rate, and only to a listed value")
        suite.expect(Defaults.registeredDefaults[DefaultsKey.recorderExportLongSide] as? Int == 0
                && Defaults.registeredDefaults[DefaultsKey.recorderExportFrameRateCap] as? Int == 0,
               "exports keep the recording's own size and rate until the person picks otherwise")
    }
}
