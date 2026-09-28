// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum RecorderTakeRecoveryTests {
    static func run(_ suite: TestSuite) {
        let open = UUID(), left = UUID(), empty = UUID()
        suite.expect(RecorderTakeRecovery.takesToReopen(
                [(id: open, hasMaster: true), (id: left, hasMaster: true), (id: empty, hasMaster: false)],
                owned: [open]) == [left],
               "a recording left by a quit reopens; one already open or never written does not")
        // An exam recording was lost when a reinstall quit the app with its
        // editor open. Quitting must never be the thing that deletes a take.
        let editorSource = (try? String(
            contentsOfFile: "Sources/Vorssaint/Services/Recorder/RecorderEditorController.swift",
            encoding: .utf8)) ?? ""
        let appSource = (try? String(
            contentsOfFile: "Sources/Vorssaint/App/AppDelegate.swift", encoding: .utf8)) ?? ""
        let recorderSource = (try? String(
            contentsOfFile: "Sources/Vorssaint/Services/Recorder/ScreenRecorderService.swift",
            encoding: .utf8)) ?? ""
        suite.expect(editorSource.contains("if !RecorderTakeRecovery.isQuitting {\n            RecorderTakeStore.shared.delete(model.take)")
                && appSource.contains("-> NSApplication.TerminateReply {\n        // Before any window closes on the way out, so an open editor keeps\n        // its recording for the next launch instead of deleting it.\n        RecorderTakeRecovery.appWillQuit()")
                && recorderSource.contains("reopenLeftoverTakes()\n        sweepTakes()"),
               "quitting keeps an open recording, and the next launch reopens it before sweeping")
    }
}
