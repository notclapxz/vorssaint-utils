// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Carbon.HIToolbox
import Foundation

enum TeleprompterTests {
    static func run(_ suite: TestSuite) {
        let perSecond = Double(TeleprompterSupport.defaultSpeed) * TeleprompterSupport.pointsPerSecondPerLevel
        suite.expect(TeleprompterSupport.advanced(offset: 0, elapsed: 1,
                                                  speed: TeleprompterSupport.defaultSpeed,
                                                  limit: 1_000) == perSecond,
               "the script scrolls by its speed for every second played")
        suite.expect(TeleprompterSupport.advanced(offset: 120, elapsed: 0, speed: 10, limit: 1_000) == 120,
               "a paused teleprompter keeps its text exactly where it was")
        suite.expect(TeleprompterSupport.advanced(offset: 990, elapsed: 5, speed: 10, limit: 1_000) == 1_000,
               "the script stops once its last line reaches the reading line")
        suite.expect(TeleprompterSupport.advanced(offset: 0, elapsed: 1, speed: 99, limit: 10_000)
                == TeleprompterSupport.advanced(offset: 0, elapsed: 1,
                                                speed: TeleprompterSupport.speedRange.upperBound,
                                                limit: 10_000)
                && TeleprompterSupport.advanced(offset: 0, elapsed: 1, speed: -3, limit: 10_000)
                == TeleprompterSupport.advanced(offset: 0, elapsed: 1, speed: 1, limit: 10_000),
               "a speed outside the steps is held to the nearest one")
        suite.expect(TeleprompterSupport.advanced(offset: 0, elapsed: 1, speed: 1, limit: 10_000) <= 6,
               "the slowest speed moves no more than a line every few seconds")
        suite.expect(TeleprompterSupport.advanced(offset: .nan, elapsed: .infinity, speed: 4, limit: .nan) == 0,
               "broken numbers never throw the text off the window")
        suite.expect(GlobalShortcutRole.teleprompter.defaultShortcut
                == GlobalShortcut(keyCode: Int64(kVK_ANSI_T), modifiers: [.shift, .control, .command])
                && GlobalShortcutRole.teleprompter.feature == .screenRecorder
                && GlobalShortcutRole.teleprompter.requiredEnableKeys == [DefaultsKey.teleprompterShortcutEnabled]
                && Defaults.registeredDefaults[DefaultsKey.teleprompterShortcutEnabled] as? Bool == false,
               "the teleprompter answers shift-control-command-T, ships off and comes with the recorder")
        // What decides whether the script shows up in a video: the recorder
        // names the window among the ones it leaves out, and the window is
        // never shared with any other capture either.
        let recorderSource = (try? String(
            contentsOfFile: "Sources/Vorssaint/Services/Recorder/ScreenRecorderService.swift",
            encoding: .utf8)) ?? ""
        let teleprompterSource = (try? String(
            contentsOfFile: "Sources/Vorssaint/Services/Teleprompter/TeleprompterService.swift",
            encoding: .utf8)) ?? ""
        suite.expect(recorderSource.contains("chrome.formUnion(TeleprompterService.shared.excludedWindowNumbers)")
                && teleprompterSource.contains("panel.sharingType = .none"),
               "the teleprompter never appears in a recording or a screenshot")
        let samplerSource = (try? String(
            contentsOfFile: "Sources/Vorssaint/Services/Recorder/RecorderPointerSampler.swift",
            encoding: .utf8)) ?? ""
        suite.expect(samplerSource.contains(
                    "guard !TeleprompterService.shared.covers(screenPoint: NSEvent.mouseLocation) else { return }"),
               "moving or pressing the teleprompter while recording never becomes an automatic zoom")
        suite.expect(Defaults.registeredDefaults[DefaultsKey.recorderTeleprompter] as? Bool == false,
               "recordings bring the teleprompter only when asked")
    }
}
