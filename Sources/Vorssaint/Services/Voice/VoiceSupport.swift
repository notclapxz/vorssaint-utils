// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The decisions behind a voice recording, kept free of AppKit so the test
/// harness can check them.
enum VoiceSupport {
    enum StartAction: Equatable {
        case countdown
        case askForMicrophone
        /// Refused before: the system will not ask again, so the only way
        /// forward is the Settings pane.
        case openMicrophoneSettings
    }

    /// A voice recording is nothing but the microphone, so unlike the screen
    /// recorder it never starts without it: an empty file would be the result.
    static func startAction(microphoneGranted: Bool, canAskForMicrophone: Bool) -> StartAction {
        if microphoneGranted { return .countdown }
        return canAskForMicrophone ? .askForMicrophone : .openMicrophoneSettings
    }
}
