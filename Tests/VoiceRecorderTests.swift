// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation

enum VoiceRecorderTests {
    static func run(_ suite: TestSuite) {
        checkStartAction(suite)
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await checkWriter(suite, rate: 48_000)
                try await checkWriter(suite, rate: 44_100)
            } catch {
                suite.expect(false, "voice writer fixture failed: \(error)")
            }
            finished.signal()
        }
        suite.expect(finished.wait(timeout: .now() + 30) == .success,
                     "voice writer scenarios finish within their bounded fixture deadline")
    }

    private static func checkStartAction(_ suite: TestSuite) {
        suite.expect(VoiceSupport.startAction(microphoneGranted: true, canAskForMicrophone: false)
                == .countdown,
               "a granted microphone goes straight to the countdown")
        suite.expect(VoiceSupport.startAction(microphoneGranted: false, canAskForMicrophone: true)
                == .askForMicrophone,
               "a microphone never asked about is asked for before anything is recorded")
        suite.expect(VoiceSupport.startAction(microphoneGranted: false, canAskForMicrophone: false)
                == .openMicrophoneSettings,
               "a refused microphone opens its Settings pane instead of recording an empty file")
        suite.expect(ScreenCaptureTool.voice.feature == .screenRecorder
                && ScreenCaptureTool.voice.dedicatedShortcut.role == .voiceRecorder
                && !ScreenCaptureTool.voice.capturesAudio
                && !ScreenCaptureTool.voice.opensDuringRecording(fromShortcut: true),
               "voice installs with the recorder, owns its shortcut and never runs over a recording")
        // A click on a window once started a voice recording, because a
        // confirmed area meant Start. Only the button and Return may.
        let chooserSource = (try? String(
            contentsOfFile: "Sources/Vorssaint/Services/QuickTools/ScreenshotSelectionController.swift",
            encoding: .utf8)) ?? ""
        let routeSource = (try? String(
            contentsOfFile: "Sources/Vorssaint/Services/QuickTools/ScreenCaptureService.swift",
            encoding: .utf8)) ?? ""
        suite.expect(chooserSource.contains("!finished && !sourceRefreshPending && activeTool != .voice")
                && routeSource.components(separatedBy: "VoiceRecorderService.shared.start()").count == 2,
               "with voice chosen, clicks and drags on screen start nothing: only Start does")
    }

    /// One second heard, one second paused, one second heard: the file keeps
    /// two seconds, in mono AAC, whatever rate the microphone delivers.
    private static func checkWriter(_ suite: TestSuite, rate: CMTimeScale) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = RecorderPauseClock()
        guard let writer = VoiceWriter(url: url, pauseClock: clock) else {
            suite.expect(false, "the voice writer opens an m4a file at \(rate) Hz")
            return
        }
        let chunk = 1_024
        func feed(from start: Double, seconds: Double) {
            var frame = 0
            let total = Int(seconds * Double(rate))
            while frame < total {
                let time = CMTime(seconds: start + Double(frame) / Double(rate),
                                  preferredTimescale: rate)
                writer.append(RecorderSampleTimingTests.audio(count: chunk, rate: rate, time: time))
                frame += chunk
            }
        }
        feed(from: 100, seconds: 1)
        _ = clock.pause(at: 101)
        feed(from: 101, seconds: 1)
        _ = clock.resume(at: 102)
        feed(from: 102, seconds: 1)
        let written = await writer.finish()
        suite.expect(written, "the voice file closes cleanly at \(rate) Hz")

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        suite.expect(abs(duration - 2) < 0.15,
                     "a paused second never reaches the voice file (\(duration) s at \(rate) Hz)")
        let track = try await asset.loadTracks(withMediaType: .audio).first
        let descriptions = try await track?.load(.formatDescriptions) ?? []
        let format = descriptions.first.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        }
        suite.expect(format?.mFormatID == kAudioFormatMPEG4AAC && format?.mChannelsPerFrame == 1,
                     "the voice file is mono AAC at \(rate) Hz")
    }
}
