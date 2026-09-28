// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreMedia

/// Records the microphone alone: the fifth tool of the capture chooser.
///
/// It borrows the recorder's pieces rather than its session, because that
/// session is built around a screen stream a voice recording never has: the
/// microphone capture, the pause clock, the pill, the countdown preference and
/// the save folder are the recorder's; only the file is its own.
final class VoiceRecorderService: ObservableObject {
    static let shared = VoiceRecorderService()

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsedSeconds = 0

    private var microphone: RecorderMicrophoneCapture?
    private var writer: VoiceWriter?
    private var pauseClock: RecorderPauseClock?
    private var fileURL: URL?
    private var indicator: RecorderIndicator?
    private var elapsedTimer: Timer?
    private var countdown: DispatchWorkItem?
    private var countdownRemaining = 0
    /// Bumped by every start and cancel, so an answer that arrives late (the
    /// microphone prompt, a countdown tick) belongs to nothing any more.
    private var generation = 0
    private var isAwaitingMicrophone = false
    private var isFinishing = false
    private var sleepActivity: NSObjectProtocol?

    private var strings: VoiceStrings { FeatureStrings.voice(L10n.shared.language) }
    private var recorderStrings: RecorderFeatureStrings {
        FeatureStrings.recorder(L10n.shared.language)
    }

    private init() {}

    var hasActiveCapture: Bool {
        isRecording || countdown != nil || isAwaitingMicrophone || isFinishing
    }

    /// The shortcut and the chooser both land here while something runs:
    /// pressing again stops what is recording, or cancels what is about to.
    func stopOrCancelActiveCapture() -> Bool {
        if isRecording {
            stop()
            return true
        }
        if countdown != nil || isAwaitingMicrophone {
            cancelPendingStart()
            return true
        }
        return isFinishing
    }

    // MARK: - Starting

    /// The chooser's Start button. The microphone is asked for before the
    /// countdown, so a permission dialog never eats the seconds to get ready.
    func start() {
        guard AppFeature.screenRecorder.isAvailable, !hasActiveCapture,
              !ScreenRecorderService.shared.hasActiveCapture else { return }
        generation &+= 1
        let generation = generation
        let permission = Permissions.shared.microphone
        switch VoiceSupport.startAction(microphoneGranted: permission == .granted,
                                        canAskForMicrophone: permission == .undetermined) {
        case .countdown:
            startCountdown(generation: generation)
        case .askForMicrophone:
            isAwaitingMicrophone = true
            Permissions.shared.requestMicrophone { [weak self] granted in
                guard let self, self.generation == generation else { return }
                self.isAwaitingMicrophone = false
                guard granted else {
                    self.reportMicrophoneUnavailable()
                    return
                }
                self.startCountdown(generation: generation)
            }
        case .openMicrophoneSettings:
            reportMicrophoneUnavailable()
            Permissions.shared.openMicrophoneSettings()
        }
    }

    private func startCountdown(generation: Int) {
        guard self.generation == generation else { return }
        countdownRemaining = ScreenshotSupport.sanitizedDelay(
            UserDefaults.standard.integer(forKey: DefaultsKey.recorderCountdown))
        tickCountdown(generation: generation)
    }

    private func tickCountdown(generation: Int) {
        guard self.generation == generation else { return }
        guard countdownRemaining > 0 else {
            countdown = nil
            beginRecording(generation: generation)
            return
        }
        QuickToolHUD.showCountdown(countdownRemaining)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            self.countdownRemaining -= 1
            self.tickCountdown(generation: generation)
        }
        countdown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func cancelPendingStart() {
        generation &+= 1
        isAwaitingMicrophone = false
        countdown?.cancel()
        countdown = nil
    }

    // MARK: - Recording

    private func beginRecording(generation: Int) {
        guard self.generation == generation, !isRecording, !isFinishing else { return }
        let clock = RecorderPauseClock()
        // Written beside the app's own files first and moved into the folder
        // only once closed: a recording cut short by a crash never leaves a
        // half file where the finished ones live.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        guard let writer = VoiceWriter(url: url, pauseClock: clock) else {
            QuickToolHUD.show(icon: "waveform", message: recorderStrings.recordFailed)
            return
        }
        let chosen = UserDefaults.standard.string(forKey: DefaultsKey.voiceMicrophoneID) ?? ""
        let microphone = RecorderMicrophoneCapture(deviceID: chosen.isEmpty ? nil : chosen)
        microphone.onSample = { [writer] sampleBuffer in writer.append(sampleBuffer) }
        self.microphone = microphone
        self.writer = writer
        pauseClock = clock
        fileURL = url

        let indicator = RecorderIndicator(
            onPause: { [weak self] in self?.togglePause() },
            onStop: { [weak self] in self?.stop() })
        indicator.show(on: Self.screenUnderPointer,
                       tooltip: strings.indicatorTooltip,
                       pauseTooltip: recorderStrings.pauseButton,
                       resumeTooltip: recorderStrings.resumeButton,
                       stopTooltip: recorderStrings.stopButton)
        indicator.update(elapsed: RecorderSupport.elapsedLabel(seconds: 0))
        self.indicator = indicator

        Task { @MainActor [weak self] in
            let started = await microphone.start(synchronizingTo: CMClockGetHostTimeClock())
            guard let self, self.generation == generation, self.microphone === microphone else {
                await microphone.stop()
                writer.cancel()
                return
            }
            guard started else {
                self.discard()
                self.reportMicrophoneUnavailable()
                return
            }
            self.recordingDidStart()
        }
    }

    private func recordingDidStart() {
        isRecording = true
        isPaused = false
        elapsedSeconds = 0
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: "Recording the microphone")
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickElapsed()
        }
        timer.tolerance = 0.1
        elapsedTimer = timer
    }

    private func tickElapsed() {
        guard isRecording, let pauseClock else { return }
        elapsedSeconds = Int(pauseClock.elapsed(at: CACurrentMediaTime()))
        indicator?.update(elapsed: RecorderSupport.elapsedLabel(seconds: elapsedSeconds))
    }

    func togglePause() {
        guard isRecording, let pauseClock else { return }
        let now = CACurrentMediaTime()
        if isPaused {
            guard pauseClock.resume(at: now) else { return }
            isPaused = false
        } else {
            guard pauseClock.pause(at: now) else { return }
            isPaused = true
        }
        elapsedSeconds = Int(pauseClock.elapsed(at: now))
        indicator?.update(elapsed: RecorderSupport.elapsedLabel(seconds: elapsedSeconds))
        indicator?.update(paused: isPaused)
    }

    // MARK: - Stopping

    func stop() {
        guard isRecording, !isFinishing, let microphone, let writer, let fileURL else { return }
        isFinishing = true
        generation &+= 1
        endRecordingSurfaces()
        Task { @MainActor [weak self] in
            // The microphone's queue is drained by its stop, so nothing is
            // still being appended when the file is closed.
            await microphone.stop()
            let written = await writer.finish()
            guard let self else { return }
            self.microphone = nil
            self.writer = nil
            self.pauseClock = nil
            self.fileURL = nil
            self.isFinishing = false
            if written {
                self.deliver(fileURL)
            } else {
                try? FileManager.default.removeItem(at: fileURL)
                QuickToolHUD.show(icon: "waveform", message: self.recorderStrings.recordFailed)
            }
        }
    }

    private func endRecordingSurfaces() {
        isRecording = false
        isPaused = false
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        indicator?.hide()
        indicator = nil
        if let sleepActivity {
            ProcessInfo.processInfo.endActivity(sleepActivity)
            self.sleepActivity = nil
        }
    }

    /// A start that failed after the file was opened: nothing reaches disk.
    private func discard() {
        endRecordingSurfaces()
        writer?.cancel()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        microphone = nil
        writer = nil
        pauseClock = nil
        fileURL = nil
    }

    // MARK: - Output

    private func deliver(_ recorded: URL) {
        let destination = ScreenRecorderService.saveDestination(prefix: strings.fileNamePrefix,
                                                                fileExtension: "m4a")
        do {
            try FileManager.default.moveItem(at: recorded, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: recorded)
            NSSound.beep()
            QuickToolHUD.show(icon: "waveform", message: recorderStrings.recordFailed)
            return
        }
        let folder = destination.deletingLastPathComponent().lastPathComponent
        QuickToolHUD.show(icon: "waveform", message: String(format: strings.savedHUDFormat, folder))
    }

    private func reportMicrophoneUnavailable() {
        QuickToolHUD.show(icon: "mic.slash", message: recorderStrings.microphoneUnavailableHUD)
    }

    /// There is no area to anchor the pill to, so it goes where the person is
    /// looking: the screen under the pointer.
    private static var screenUnderPointer: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }
}
