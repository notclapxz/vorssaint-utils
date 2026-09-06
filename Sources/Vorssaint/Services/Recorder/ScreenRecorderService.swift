// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation
import AppKit
import CoreMedia

/// The three choices shown while the area is being picked: what the recording
/// hears, and whether it also carries the face of whoever is talking. They
/// write through to preferences immediately, so the selection and Settings
/// always start alike.
final class RecorderSelectionTrackOptions: ObservableObject {
    @Published var systemAudio: Bool {
        didSet { UserDefaults.standard.set(systemAudio, forKey: DefaultsKey.recorderSystemAudio) }
    }
    @Published var microphone: Bool {
        didSet { UserDefaults.standard.set(microphone, forKey: DefaultsKey.recorderMicrophone) }
    }
    @Published var camera: Bool {
        didSet { UserDefaults.standard.set(camera, forKey: DefaultsKey.recorderCamera) }
    }

    init(defaults: UserDefaults = .standard) {
        systemAudio = defaults.bool(forKey: DefaultsKey.recorderSystemAudio)
        microphone = defaults.bool(forKey: DefaultsKey.recorderMicrophone)
        camera = defaults.bool(forKey: DefaultsKey.recorderCamera)
    }
}

/// One recording, from the first frame to the closed file. Everything that
/// only exists while recording lives here and dies with it, so the service
/// itself keeps nothing running between recordings.
private final class RecorderSession: NSObject, RecorderCaptureEngineDelegate {
    let take: RecorderTakeStore.Take
    let region: RecorderSupport.Region
    private let engine = RecorderCaptureEngine()
    private let pauseClock = RecorderPauseClock()
    /// Claimed by the screen's first sample and read by the camera's writer,
    /// so both files start counting from the same instant.
    private let timeOrigin = RecorderTimeOrigin()
    private let microphone: RecorderMicrophoneCapture?
    /// The camera and the file it writes: the face is a second video beside
    /// the screen, never inside it, so the editor still owns where it sits.
    private let camera: RecorderCameraCapture?
    private let cameraWriter: RecorderCameraWriter?
    private let capturesSystemAudio: Bool
    /// The Mac's sound read once per process, when the audio system grants
    /// one. Both it and the stream's audio run whenever the Mac's sound is
    /// wanted; which of the two the file receives is settled in `start()`.
    private var systemAudioTap: RecorderSystemAudioTap?
    private var writesTapAudio = false
    /// Raised when an output device change costs the tap its reader mid
    /// recording. One way, and read from the audio threads, so it is the flag
    /// type rather than a plain Bool.
    private let tapReaderLost = RecorderAudioFlag()
    private let streamHeard = RecorderAudioFlag()
    private let pointer: RecorderPointerSampler
    private let typing: RecorderTypingSampler
    /// Follows the viewer while recording, so where the face was dragged to is
    /// replayed by the editor instead of being lost with the panel.
    private let cameraSampler: RecorderCameraSampler?
    private let writerQueue = DispatchQueue(label: "com.vorssaint.recorder.writer",
                                            qos: .userInitiated)
    private let startGate = RecorderStartGate()
    /// Immutable for the whole session, which is what makes it safe to touch
    /// from the capture queue while the main thread watches the clock.
    private let writer: RecorderWriter

    var onUnexpectedStop: ((RecorderFailure) -> Void)?
    var onMicrophoneUnavailable: (() -> Void)?
    var onCameraUnavailable: (() -> Void)?

    /// The session the mirror draws while recording, so what is watched is
    /// what is written rather than a second look at the same camera.
    var cameraSession: AVCaptureSession? { camera?.session }

    /// The camera arrives already built, and often already running: the mirror
    /// shown while the area was picked is on the very session that records, so
    /// nothing blinks or restarts when the countdown ends.
    init?(take: RecorderTakeStore.Take,
          region: RecorderSupport.Region,
          frameRate: Int,
          capturesSystemAudio: Bool,
          capturesMicrophone: Bool,
          camera: RecorderCameraCapture?) {
        guard let writer = RecorderWriter(url: take.videoURL,
                                          pixelSize: region.pixelSize,
                                          frameRate: frameRate,
                                          capturesSystemAudio: capturesSystemAudio,
                                          capturesMicrophone: capturesMicrophone,
                                          pauseClock: pauseClock,
                                          timeOrigin: timeOrigin)
        else { return nil }
        self.take = take
        self.region = region
        self.writer = writer
        self.capturesSystemAudio = capturesSystemAudio
        microphone = capturesMicrophone ? RecorderMicrophoneCapture() : nil
        // A camera that cannot be written to is a camera that is not recorded:
        // the screen is what the person asked for, and losing it over a second
        // file that could not be opened would be the worse failure.
        if camera != nil,
           let cameraWriter = RecorderCameraWriter(url: take.cameraURL,
                                                   frameRate: RecorderSupport.cameraFrameRate,
                                                   pauseClock: pauseClock,
                                                   timeOrigin: timeOrigin) {
            self.cameraWriter = cameraWriter
            self.camera = camera
        } else {
            cameraWriter = nil
            self.camera = nil
        }
        pointer = RecorderPointerSampler(region: region, pauseClock: pauseClock)
        typing = RecorderTypingSampler(pauseClock: pauseClock)
        cameraSampler = camera == nil
            ? nil
            : RecorderCameraSampler(region: region, pauseClock: pauseClock)
        super.init()
        engine.delegate = self
        microphone?.onSample = { [weak self] sampleBuffer in
            self?.append(sampleBuffer, kind: .microphone)
        }
        camera?.onSample = { [weak self] sampleBuffer in
            self?.appendCameraSample(sampleBuffer)
        }
    }

    func start(frameRate: Int,
               capturesSystemAudio: Bool,
               excludedWindowNumbers: [Int]) async -> RecorderFailure? {
        guard startGate.begin() else { return .streamFailed }
        defer { startGate.finish() }
        guard writer.start() else {
            _ = startGate.claimStartFailure()
            return .writerFailed
        }
        if capturesSystemAudio {
            systemAudioTap = await RecorderSystemAudioTap.make()
        }
        let tap = systemAudioTap
        // A tap that has not yet heard sound on this Mac may be waiting on a
        // permission, and it answers that with silence, not an error. The
        // stream's sound is written until the tap has proven itself.
        writesTapAudio = tap != nil
            && UserDefaults.standard.bool(forKey: DefaultsKey.recorderSystemAudioTapVerified)
        tap?.onSample = { [weak self] sampleBuffer in
            self?.appendTapSample(sampleBuffer)
        }
        tap?.onReaderLost = { [weak self] in self?.tapReaderLost.raise() }
        if let failure = await engine.start(region: region,
                                            frameRate: frameRate,
                                            capturesSystemAudio: capturesSystemAudio,
                                            excludedWindowNumbers: excludedWindowNumbers,
                                            isCancelled: { [weak self] in
                                                self?.startGate.isAuthorized != true
                                            }) {
            if startGate.claimStartFailure() { writer.cancel() }
            await tap?.stop()
            return failure
        }
        guard startGate.isAuthorized else {
            await tap?.stop()
            await engine.stop()
            return .streamFailed
        }
        // The tap starts before the microphone so the Mac's sound has the
        // shortest possible gap at the head of the file while it comes up.
        if let tap, let clock = engine.synchronizationClock {
            let started = await tap.start(synchronizingTo: clock)
            // A trusted tap that could not build a reader this time (no output
            // device, or a permission just revoked) would otherwise leave the
            // file's sound silent, since the stream's copy is being dropped.
            if writesTapAudio, !started { writesTapAudio = false }
        }
        guard startGate.isAuthorized else {
            await tap?.stop()
            await engine.stop()
            return .streamFailed
        }
        if let microphone, let clock = engine.synchronizationClock {
            if await microphone.start(synchronizingTo: clock) == false {
                onMicrophoneUnavailable?()
            }
            guard startGate.isAuthorized else {
                await tap?.stop()
                await microphone.stop()
                await engine.stop()
                return .streamFailed
            }
        }
        // Last of the sources, so the screen has already claimed the zero the
        // camera's frames are measured against.
        if let camera, let clock = engine.synchronizationClock {
            // A camera warmed up during the picker only needs the clock; one
            // that was never warmed has to be started here.
            if camera.isRunning {
                camera.synchronize(to: clock)
            } else if await camera.start(synchronizingTo: clock) == false {
                onCameraUnavailable?()
            }
            guard startGate.isAuthorized else {
                await tap?.stop()
                await microphone?.stop()
                await camera.stop()
                await engine.stop()
                return .streamFailed
            }
        }
        // This method is nonisolated and async, so its body runs on the
        // cooperative pool however main-actor the caller was (SE-0338). The
        // two samplers install AppKit event monitors, which belong to the
        // main thread's dispatch, so they are started and stopped there.
        await MainActor.run {
            pointer.start()
            typing.start()
        }
        return nil
    }

    /// The viewer belongs to the service, which owns it from before the
    /// recording existed, so following it starts once it is on screen and the
    /// stream is already running.
    @MainActor
    func followCamera(_ panel: NSWindow) {
        cameraSampler?.start(panel: panel)
    }

    /// A viewer moved while paused reported that move into a stretch that is
    /// not part of the recording, so where it ended up is asked for again.
    func noteCameraResumed() {
        cameraSampler?.markMoved()
    }

    var isPaused: Bool { pauseClock.isPaused }

    func pause(at time: CFTimeInterval) -> Bool {
        pauseClock.pause(at: time)
    }

    func resume(at time: CFTimeInterval) -> Bool {
        pauseClock.resume(at: time)
    }

    func elapsed(since origin: CFTimeInterval, at time: CFTimeInterval) -> Double {
        pauseClock.elapsed(since: origin, at: time)
    }

    /// Stops the stream first and waits for it, so the file is closed knowing
    /// no further frame can arrive.
    func stop() async -> Bool {
        let ownsFinalization = startGate.cancelAndClaimStop()
        await startGate.waitUntilFinished()
        guard ownsFinalization else { return false }
        let tap = systemAudioTap
        let microphone = self.microphone
        let camera = self.camera
        async let tapStop: Void = { if let tap { await tap.stop() } }()
        async let microphoneStop: Void = { if let microphone { await microphone.stop() } }()
        async let cameraStop: Void = { if let camera { await camera.stop() } }()
        await engine.stop()
        await microphoneStop
        await cameraStop
        await tapStop
        // A tap that lost its reader was cut short by a device change, not by a
        // missing permission, so this recording proves nothing either way.
        if let tap, !tapReaderLost.value {
            UserDefaults.standard.set(
                RecorderSupport.trustsSystemAudioTap(previously: writesTapAudio,
                                                     tapHeardSound: tap.heardSound,
                                                     streamHeardSound: streamHeard.value),
                forKey: DefaultsKey.recorderSystemAudioTapVerified)
        }
        let (track, typingTrack, cameraTrack) = await MainActor.run {
            (pointer.stop(), typing.stop(), cameraSampler?.stop())
        }
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        writerQueue.sync {}
        let written = await writer.finish(at: end)
        // Every camera frame has been handed to the writer queue by now, and
        // the queue has been drained, so the second file can be closed knowing
        // nothing is still in flight. A recording whose screen could not be
        // written leaves no orphan face behind either.
        if let cameraWriter {
            if written {
                _ = await cameraWriter.finish()
            } else {
                cameraWriter.cancel()
            }
        }
        if written, !track.isEmpty {
            try? track.encoded().write(to: take.pointerURL, options: .atomic)
        }
        if written, !typingTrack.isEmpty, let data = typingTrack.encoded() {
            try? data.write(to: take.typingURL, options: .atomic)
        }
        if written, let cameraTrack, !cameraTrack.isEmpty,
           let data = cameraTrack.encoded() {
            try? data.write(to: take.cameraTrackURL, options: .atomic)
        }
        return written
    }

    func captureEngine(_ engine: RecorderCaptureEngine,
                       didOutput sampleBuffer: CMSampleBuffer,
                       of kind: RecorderCaptureEngine.Kind) {
        if kind == .systemAudio {
            // The stream keeps listening even when the tap is written: a tap
            // that stays silent through sound the stream heard has lost its
            // permission, and the next recording goes back to the stream.
            if !streamHeard.value, RecorderAudioProbe.containsSound(sampleBuffer) {
                streamHeard.raise()
            }
            if writesTapAudio, !tapReaderLost.value { return }
        }
        append(sampleBuffer, kind: kind)
    }

    private func appendTapSample(_ sampleBuffer: CMSampleBuffer) {
        guard writesTapAudio, !tapReaderLost.value else { return }
        append(sampleBuffer, kind: .systemAudio)
    }

    func captureEngine(_ engine: RecorderCaptureEngine, didStopWith failure: RecorderFailure) {
        onUnexpectedStop?(failure)
    }

    private func append(_ sampleBuffer: CMSampleBuffer, kind: RecorderCaptureEngine.Kind) {
        writerQueue.async { [writer] in
            writer.append(sampleBuffer, kind: kind)
        }
    }

    /// The camera writes to its own file but on the same queue, which is what
    /// lets the two writers share one zero without a lock between them.
    private func appendCameraSample(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [cameraWriter] in
            cameraWriter?.append(sampleBuffer)
        }
    }
}

/// The screen recorder: picks an area the same way the screenshot tool does,
/// records it with either optional sound source, and leaves a video file behind.
///
/// At rest it holds no recorder resource; the shared capture service owns the
/// optional global shortcut. The stream, writer, floating indicator and the
/// one timer that draws elapsed time are created only while recording.
final class ScreenRecorderService: ObservableObject {
    static let shared = ScreenRecorderService()

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsedSeconds = 0
    private var session: RecorderSession?
    private var indicator: RecorderIndicator?
    /// Up while a recording carrying the camera runs AND while the area is
    /// still being picked, and left out of the capture either way, so the face
    /// lands in the video once and where the editor puts it rather than twice.
    private var cameraPreview: RecorderCameraPreview?
    /// The camera started while the area is being picked, waiting for the
    /// recording that will adopt it. Held here rather than in the session
    /// because it exists before there is a session at all.
    private var warmCamera: RecorderCameraCapture?
    private var editors: [RecorderEditorController] = []
    private var mediaOwnedEditorIDs: Set<ObjectIdentifier> = []
    private var elapsedTimer: Timer?
    private var startedAt: CFTimeInterval = 0
    private var countdown: DispatchWorkItem?
    private var countdownRemaining = 0
    private var pendingStartGeneration = 0
    private var isAwaitingMicrophone = false
    private var isAwaitingCamera = false
    private var sleepActivity: NSObjectProtocol?
    /// Set while a stop is being finalized, so a second press of the shortcut
    /// cannot start a recording on top of one still closing its file.
    private var isFinishing = false
    /// Set while the disk is being asked how much room is left, so a slow
    /// answer cannot pile the next second's question on top of it.
    private var isCheckingDisk = false

    private var strings: RecorderFeatureStrings {
        FeatureStrings.recorder(L10n.shared.language)
    }

    private init() {}

    // MARK: - Preferences

    func syncWithPreferences() {
        guard AppFeature.screenRecorder.isAvailable else {
            teardownSurfaces()
            return
        }
        sweepTakes()
    }

    /// Uninstalling the feature in the hub has to take everything off the
    /// screen, but a recording in progress still finishes into a file: losing
    /// what was already recorded would be worse than the delay.
    private func teardownSurfaces() {
        invalidatePendingStart()
        let recorderOwnedEditors = editors.filter {
            !mediaOwnedEditorIDs.contains(ObjectIdentifier($0))
        }
        for editor in recorderOwnedEditors {
            editor.close()
        }
        if session != nil {
            stop()
        }
    }

    // MARK: - Editor

    @discardableResult
    func openEditor(with take: RecorderTakeStore.Take,
                    owner: AppFeature = .screenRecorder) -> Bool {
        guard owner.isAvailable else { return false }
        WindowActivationPolicy.retain()
        let editor = RecorderEditorController(take: take)
        editors.append(editor)
        if owner == .mediaTools { mediaOwnedEditorIDs.insert(ObjectIdentifier(editor)) }
        editor.show()
        return true
    }

    func editorDidClose(_ editor: RecorderEditorController) {
        guard editors.contains(where: { $0 === editor }) else { return }
        editors.removeAll { $0 === editor }
        mediaOwnedEditorIDs.remove(ObjectIdentifier(editor))
        WindowActivationPolicy.release()
    }

    func closeEditors(ownedBy owner: AppFeature) {
        guard owner == .mediaTools else { return }
        let targets = editors.filter { mediaOwnedEditorIDs.contains(ObjectIdentifier($0)) }
        for editor in targets { editor.close() }
    }

    // MARK: - Entry

    /// The one control the shortcut, the panel tile and the command bar all
    /// use: it starts when nothing is running and stops when something is.
    func toggle() {
        if stopOrCancelActiveCapture() { return }
        ScreenCaptureService.shared.capture(initial: .recording)
    }

    var hasActiveCapture: Bool {
        isRecording || session != nil || countdown != nil || isAwaitingMicrophone || isFinishing
    }

    func stopOrCancelActiveCapture() -> Bool {
        if isRecording || session != nil {
            stop()
            return true
        }
        if countdown != nil {
            invalidatePendingStart()
            return true
        }
        if isAwaitingMicrophone || isAwaitingCamera {
            invalidatePendingStart()
            return true
        }
        return isFinishing
    }

    func prepareForSelection() -> Bool {
        guard AppFeature.screenRecorder.isAvailable, !isFinishing,
              session == nil, countdown == nil,
              !isAwaitingMicrophone, !isAwaitingCamera else { return false }
        guard Permissions.shared.screenRecording else {
            Permissions.shared.requestScreenRecording()
            return false
        }
        guard Permissions.shared.accessibility else {
            Permissions.shared.requestAccessibility()
            return false
        }
        guard RecorderSupport.canStart(freeBytes: RecorderTakeStore.shared.freeBytes()) else {
            reportNoSpace()
            return false
        }
        return true
    }

    /// Shows the mirror while the area is still being picked, so framing and
    /// light are fixed before the countdown instead of being discovered in the
    /// finished recording. What is shown is the session that will record, so
    /// nothing restarts, blinks or re-frames when the countdown ends.
    func previewCamera(_ on: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.previewCamera(on) }
            return
        }
        guard on else {
            endCamera(warmCamera)
            warmCamera = nil
            // A recording that already adopted a camera keeps its own mirror.
            if session == nil { hideCameraPreview() }
            return
        }
        // Never during a recording, and never before the camera has been
        // allowed: the system's permission dialog cannot be answered under the
        // picker's overlay, so that question waits for the countdown.
        guard session == nil, warmCamera == nil, cameraPreview == nil,
              AppFeature.screenRecorder.isAvailable,
              Permissions.shared.camera == .granted,
              RecorderCameraCapture.hasCamera else { return }
        let camera = RecorderCameraCapture()
        warmCamera = camera
        Task { @MainActor [weak self] in
            let started = await camera.startPreview()
            // The picker may have been dismissed, or the camera turned off
            // again, while it was coming up.
            guard let self, self.warmCamera === camera else {
                await camera.stop()
                return
            }
            guard started else {
                self.warmCamera = nil
                return
            }
            guard self.cameraPreview == nil else { return }
            let preview = RecorderCameraPreview()
            preview.show(session: camera.session, on: NSScreen.main, abovePicker: true)
            self.cameraPreview = preview
        }
    }

    /// Ends a camera no recording took. Stopping a capture session blocks, so
    /// it never happens on the main thread.
    private func endCamera(_ camera: RecorderCameraCapture?) {
        guard let camera else { return }
        Task.detached { await camera.stop() }
    }

    func record(_ region: RecorderSupport.Region,
                trackOptions: RecorderSelectionTrackOptions) {
        guard prepareForSelection() else { return }
        let indicator = RecorderIndicator(
            onPause: { [weak self] in self?.togglePause() },
            onStop: { [weak self] in self?.stop() })
        indicator.showRegionGuide(for: region)
        self.indicator = indicator
        pendingStartGeneration &+= 1
        let generation = pendingStartGeneration
        prepareCountdown(for: region, wantsMicrophone: trackOptions.microphone,
                         wantsCamera: trackOptions.camera,
                         generation: generation)
    }

    /// Each optional source is asked for in turn before the countdown starts:
    /// a permission dialog in the middle of a countdown would eat the seconds
    /// the person was given to get ready.
    private func prepareCountdown(for region: RecorderSupport.Region,
                                  wantsMicrophone: Bool,
                                  wantsCamera: Bool,
                                  generation: Int) {
        guard pendingStartIsAuthorized(generation) else { return }
        guard wantsMicrophone else {
            prepareCamera(for: region, wantsCamera: wantsCamera, generation: generation)
            return
        }
        switch Permissions.shared.microphone {
        case .granted:
            prepareCamera(for: region, wantsCamera: wantsCamera, generation: generation)
        case .undetermined:
            isAwaitingMicrophone = true
            Permissions.shared.requestMicrophone { [weak self] granted in
                guard let self, self.pendingStartIsAuthorized(generation) else { return }
                self.isAwaitingMicrophone = false
                if !granted {
                    QuickToolHUD.show(icon: "mic.slash",
                                      message: self.strings.microphoneUnavailableHUD)
                }
                self.prepareCamera(for: region, wantsCamera: wantsCamera, generation: generation)
            }
        case .denied, .unknown:
            QuickToolHUD.show(icon: "mic.slash", message: strings.microphoneUnavailableHUD)
            prepareCamera(for: region, wantsCamera: wantsCamera, generation: generation)
        }
    }

    /// A camera that was asked for and cannot be had costs the recording
    /// nothing but the face: the screen is still what the person came for, so
    /// every unhappy answer here still ends in a recording.
    private func prepareCamera(for region: RecorderSupport.Region,
                               wantsCamera: Bool,
                               generation: Int) {
        guard pendingStartIsAuthorized(generation) else { return }
        guard wantsCamera else {
            startCountdown(for: region, generation: generation)
            return
        }
        guard RecorderCameraCapture.hasCamera else {
            QuickToolHUD.show(icon: "video.slash", message: strings.cameraUnavailableHUD)
            startCountdown(for: region, generation: generation)
            return
        }
        switch Permissions.shared.camera {
        case .granted:
            startCountdown(for: region, generation: generation)
        case .undetermined:
            isAwaitingCamera = true
            Permissions.shared.requestCamera { [weak self] granted in
                guard let self, self.pendingStartIsAuthorized(generation) else { return }
                self.isAwaitingCamera = false
                if !granted {
                    QuickToolHUD.show(icon: "video.slash",
                                      message: self.strings.cameraUnavailableHUD)
                }
                self.startCountdown(for: region, generation: generation)
            }
        case .denied, .unknown:
            QuickToolHUD.show(icon: "video.slash", message: strings.cameraUnavailableHUD)
            startCountdown(for: region, generation: generation)
        }
    }

    // MARK: - Countdown

    private func startCountdown(for region: RecorderSupport.Region, generation: Int) {
        guard pendingStartIsAuthorized(generation), session == nil, !isFinishing else { return }
        let delay = ScreenshotSupport.sanitizedDelay(
            UserDefaults.standard.integer(forKey: DefaultsKey.recorderCountdown))
        guard delay > 0 else {
            beginRecording(region: region, generation: generation)
            return
        }
        countdownRemaining = delay
        tickCountdown(region: region, generation: generation)
    }

    private func tickCountdown(region: RecorderSupport.Region, generation: Int) {
        guard pendingStartIsAuthorized(generation) else { return }
        guard countdownRemaining > 0 else {
            countdown = nil
            beginRecording(region: region, generation: generation)
            return
        }
        QuickToolHUD.showCountdown(countdownRemaining)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingStartIsAuthorized(generation) else { return }
            self.countdownRemaining -= 1
            self.tickCountdown(region: region, generation: generation)
        }
        countdown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: - Recording

    private func beginRecording(region: RecorderSupport.Region, generation: Int) {
        guard pendingStartIsAuthorized(generation), session == nil,
              !isFinishing, let take = RecorderTakeStore.shared.makeTake() else {
            indicator?.hide()
            indicator = nil
            QuickToolHUD.show(icon: "record.circle", message: strings.recordFailed)
            return
        }
        let defaults = UserDefaults.standard
        let frameRate = RecorderSupport.sanitizedFrameRate(
            defaults.integer(forKey: DefaultsKey.recorderFrameRate))
        let capturesSystemAudio = defaults.bool(forKey: DefaultsKey.recorderSystemAudio)
        let capturesMicrophone = defaults.bool(forKey: DefaultsKey.recorderMicrophone)
            && Permissions.shared.microphone == .granted
        let capturesCamera = defaults.bool(forKey: DefaultsKey.recorderCamera)
            && Permissions.shared.camera == .granted
        // The camera warmed up under the picker is handed straight to the
        // recording; one that never warmed up is built now and started with
        // the stream.
        let warmedCamera = warmCamera
        warmCamera = nil
        let camera = capturesCamera ? (warmedCamera ?? RecorderCameraCapture()) : nil
        guard let session = RecorderSession(take: take,
                                            region: region,
                                            frameRate: frameRate,
                                            capturesSystemAudio: capturesSystemAudio,
                                            capturesMicrophone: capturesMicrophone,
                                            camera: camera) else {
            indicator?.hide()
            indicator = nil
            endCamera(camera ?? warmedCamera)
            hideCameraPreview()
            RecorderTakeStore.shared.delete(take)
            QuickToolHUD.show(icon: "record.circle", message: strings.recordFailed)
            return
        }
        if session.cameraSession == nil {
            // Either the person turned the camera off after warming it, or no
            // file could be opened for the face. Both end the same way: nothing
            // keeps a camera running that nothing is going to write.
            endCamera(camera ?? warmedCamera)
            hideCameraPreview()
        }
        session.onUnexpectedStop = { [weak self] _ in
            // The stream ended without being asked to. Whatever was recorded
            // is still worth keeping, so this closes the file rather than
            // throwing the take away.
            self?.stop()
        }
        session.onMicrophoneUnavailable = { [weak self] in
            guard let self else { return }
            QuickToolHUD.show(icon: "mic.slash", message: self.strings.microphoneUnavailableHUD)
        }
        session.onCameraUnavailable = { [weak self] in
            guard let self else { return }
            // The recording carries on without the face: a camera taken by
            // another app is not a reason to lose the screen.
            self.hideCameraPreview()
            QuickToolHUD.show(icon: "video.slash", message: self.strings.cameraUnavailableHUD)
        }
        self.session = session

        // The indicator goes up BEFORE the stream is asked to start, because
        // the capture filter names the windows it leaves out and can only name
        // the ones that already exist. Everything else this app shows stays in
        // the picture.
        let indicator = indicator ?? RecorderIndicator(
            onPause: { [weak self] in self?.togglePause() },
            onStop: { [weak self] in self?.stop() })
        indicator.show(on: NSScreen.screens.first { $0.displayID == region.displayID },
                       tooltip: strings.indicatorTooltip,
                       pauseTooltip: strings.pauseButton,
                       resumeTooltip: strings.resumeButton,
                       stopTooltip: strings.stopButton)
        indicator.update(elapsed: RecorderSupport.elapsedLabel(seconds: 0))
        self.indicator = indicator

        // The mirror goes up with the pill and for the same reason: the filter
        // can only leave out windows that already exist when it is built. One
        // already up from the picker is kept and simply dropped to the pill's
        // level, so the face never blinks between picking and recording.
        if let cameraSession = session.cameraSession {
            if let preview = cameraPreview {
                preview.settleForRecording()
            } else {
                let preview = RecorderCameraPreview()
                preview.show(session: cameraSession,
                             on: NSScreen.screens.first { $0.displayID == region.displayID })
                cameraPreview = preview
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // The selection panels have just left the screen; the stream is
            // told to start only once the window server has caught up, so the
            // first frames are of the desktop and not of a fading overlay.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard self.session === session,
                  self.pendingStartIsAuthorized(generation) else { return }
            var chrome = Set(ScreenshotService.shared.protectedWindowIDsForCapture.map(Int.init))
            chrome.formUnion(indicator.excludedWindowNumbers)
            chrome.formUnion(self.cameraPreview?.excludedWindowNumbers ?? [])
            if let number = QuickToolHUD.currentWindowNumber { chrome.insert(number) }
            let failure = await session.start(frameRate: frameRate,
                                              capturesSystemAudio: capturesSystemAudio,
                                              excludedWindowNumbers: Array(chrome))
            guard self.session === session, !self.isFinishing,
                  self.pendingStartIsAuthorized(generation) else { return }
            if let failure {
                self.session = nil
                self.indicator?.hide()
                self.indicator = nil
                self.hideCameraPreview()
                RecorderTakeStore.shared.delete(take)
                self.report(failure)
                return
            }
            if let window = self.cameraPreview?.window {
                session.followCamera(window)
            }
            self.recordingDidStart()
        }
    }

    private func pendingStartIsAuthorized(_ generation: Int) -> Bool {
        RecorderSupport.pendingStartIsAuthorized(
            requestGeneration: generation,
            currentGeneration: pendingStartGeneration,
            featureIsAvailable: AppFeature.screenRecorder.isAvailable)
    }

    private func invalidatePendingStart() {
        pendingStartGeneration &+= 1
        isAwaitingMicrophone = false
        isAwaitingCamera = false
        countdown?.cancel()
        countdown = nil
        indicator?.hide()
        indicator = nil
        endCamera(warmCamera)
        warmCamera = nil
        hideCameraPreview()
    }

    /// Takes the mirror down. Safe to call when there is none, and safe to
    /// call from the capture queue: the panel belongs to the main thread.
    private func hideCameraPreview() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.hideCameraPreview() }
            return
        }
        cameraPreview?.hide()
        cameraPreview = nil
    }

    private func recordingDidStart() {
        isRecording = true
        isPaused = false
        elapsedSeconds = 0
        startedAt = CACurrentMediaTime()
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: "Recording the screen")

        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickElapsed()
        }
        timer.tolerance = 0.1
        elapsedTimer = timer
    }

    private func tickElapsed() {
        guard isRecording, let session else { return }
        elapsedSeconds = Int(session.elapsed(since: startedAt, at: CACurrentMediaTime()))
        indicator?.update(elapsed: RecorderSupport.elapsedLabel(seconds: elapsedSeconds))
        checkDiskSpace()
    }

    func togglePause() {
        guard isRecording, let session else { return }
        let now = CACurrentMediaTime()
        if session.isPaused {
            guard session.resume(at: now) else { return }
            isPaused = false
            session.noteCameraResumed()
        } else {
            guard session.pause(at: now) else { return }
            isPaused = true
        }
        elapsedSeconds = Int(session.elapsed(since: startedAt, at: now))
        indicator?.update(elapsed: RecorderSupport.elapsedLabel(seconds: elapsedSeconds))
        indicator?.update(paused: isPaused)
    }

    /// A recording that fills the disk is a much worse failure than one that
    /// stopped early, so the free space is checked while it runs. Asking the
    /// system how much room is left has to account for purgeable files, which
    /// makes it slow enough that it can never ride the main thread: only the
    /// decision to stop comes back.
    private func checkDiskSpace() {
        guard !isCheckingDisk, let asked = session?.take.id else { return }
        isCheckingDisk = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let low = RecorderSupport.shouldStopForDisk(
                freeBytes: RecorderTakeStore.shared.freeBytes())
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCheckingDisk = false
                // The answer belongs to the recording that asked for it: one
                // that lands late says nothing about the one running now.
                guard low, self.isRecording, self.session?.take.id == asked else { return }
                self.stop(reason: self.strings.stoppedNoSpaceHUD)
            }
        }
    }

    // MARK: - Stopping

    func stop(reason: String? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop(reason: reason) }
            return
        }
        guard let session, !isFinishing else { return }
        isFinishing = true
        invalidatePendingStart()
        endRecordingSurfaces()

        Task { @MainActor [weak self] in
            let written = await session.stop()
            guard let self else { return }
            self.session = nil
            self.isFinishing = false
            if written {
                self.deliver(session.take, reason: reason)
            } else {
                RecorderTakeStore.shared.delete(session.take)
                QuickToolHUD.show(icon: "record.circle", message: self.strings.recordFailed)
            }
            self.sweepTakes()
        }
    }

    private func endRecordingSurfaces() {
        isRecording = false
        isPaused = false
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if let sleepActivity {
            ProcessInfo.processInfo.endActivity(sleepActivity)
            self.sleepActivity = nil
        }
    }

    // MARK: - Output

    /// A finished recording either opens in the editor, which is where trim,
    /// sound and format are decided, or goes straight to a file for whoever
    /// only wanted the raw recording.
    private func deliver(_ take: RecorderTakeStore.Take, reason: String?) {
        // A recording that carried the camera always opens the editor, whatever
        // the preference says: the face is a second file, and saving the master
        // straight to disk would quietly drop it. Turning the camera off is a
        // decision that belongs to the person, not to a preference they set for
        // recordings without one.
        let carriesCamera = FileManager.default.fileExists(atPath: take.cameraURL.path)
        if reason == nil,
           carriesCamera || UserDefaults.standard.bool(forKey: DefaultsKey.recorderOpenEditor) {
            if openEditor(with: take) { return }
        }
        saveDirect(take, reason: reason)
    }

    private func saveDirect(_ take: RecorderTakeStore.Take, reason: String?) {
        let destination = Self.saveDestination(strings: strings, fileExtension: "mov")
        do {
            try RecorderTakeStore.shared.saveDirectly(take, to: destination)
        } catch {
            NSSound.beep()
            QuickToolHUD.show(icon: "record.circle", message: strings.recordFailed)
            openEditor(with: take)
            return
        }
        RecentCaptureService.shared.recordRecording(at: destination)
        let folder = destination.deletingLastPathComponent().lastPathComponent
        QuickToolHUD.show(icon: "record.circle",
                          message: reason ?? String(format: strings.savedHUDFormat, folder))
    }

    /// The configured folder when it still exists, otherwise the Desktop, with
    /// a unique dated name. Deliberately the same shape the screenshot tool
    /// uses, so both tools behave the same way about where things land.
    static func saveDestination(strings: RecorderFeatureStrings,
                                fileExtension: String) -> URL {
        let manager = FileManager.default
        var folder: URL?
        let stored = UserDefaults.standard.string(forKey: DefaultsKey.recorderSaveFolder) ?? ""
        if !stored.isEmpty {
            let expanded = (stored as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: expanded, isDirectory: &isDirectory),
               isDirectory.boolValue {
                folder = URL(fileURLWithPath: expanded)
            }
        }
        let destination = folder
            ?? manager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser
        let name = ScreenshotSupport.fileName(prefix: strings.fileNamePrefix,
                                              date: Date(),
                                              fileExtension: fileExtension)
        let unique = ScreenshotSupport.uniqueFileName(name) { candidate in
            manager.fileExists(atPath: destination.appendingPathComponent(candidate).path)
        }
        return destination.appendingPathComponent(unique)
    }

    // MARK: - Failures

    private func report(_ failure: RecorderFailure) {
        switch failure {
        case .permissionDenied:
            Permissions.shared.requestScreenRecording()
        case .diskFull:
            reportNoSpace()
        case .noContent, .streamFailed, .writerFailed:
            QuickToolHUD.show(icon: "record.circle", message: strings.recordFailed)
        }
    }

    private func reportNoSpace() {
        let alert = NSAlert()
        alert.messageText = strings.noSpaceTitle
        alert.informativeText = strings.noSpaceMessage
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Retention

    private func sweepTakes() {
        // Read on the main thread, where the editors live, and handed over as
        // a value: a recording with a window on screen is never swept.
        var owned = Set(editors.map(\.takeID))
        if let session { owned.insert(session.take.id) }
        DispatchQueue.global(qos: .utility).async {
            RecorderTakeStore.shared.sweep(keeping: owned)
        }
    }
}
