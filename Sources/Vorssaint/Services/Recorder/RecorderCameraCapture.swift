// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation
import CoreMedia
import Foundation

/// Captures the camera while a recording asks for it, and hands its frames
/// over untouched. It also runs, silently, while the area is being picked, so
/// the same session that will record is the one already on screen when the
/// countdown starts.
///
/// The face is written to a file of its own beside the screen's rather than
/// burnt into the picture: where it sits, how big it is and whether it is
/// there at all are the things people change after recording, and a composited
/// frame settles all three at the moment of capture. Its timestamps are
/// converted onto ScreenCaptureKit's clock before the writer sees them, the
/// same way the microphone's are, so the face and the screen share one
/// timeline.
final class RecorderCameraCapture: NSObject,
                                   AVCaptureVideoDataOutputSampleBufferDelegate,
                                   @unchecked Sendable {
    var onSample: ((CMSampleBuffer) -> Void)?

    /// The running session, so the mirror shown while recording draws the very
    /// picture being written instead of opening a second session to fight the
    /// first one for the same camera.
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.vorssaint.recorder.camera",
                                      qos: .userInitiated)
    private var targetClock: CMClock?
    private var configured = false

    /// Whether there is a camera to record at all, so the recorder can drop
    /// the request before it promises a face it cannot deliver.
    static var hasCamera: Bool { device() != nil }

    /// Runs the camera without a clock: it shows, but emits nothing. That is
    /// what lets the mirror be up while the area is still being picked, on the
    /// very session the recording will use, instead of opening a second one
    /// and making the camera light blink between them.
    func startPreview() async -> Bool {
        await start(synchronizingTo: nil)
    }

    func start(synchronizingTo clock: CMClock?) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard configureIfNeeded() else {
                    continuation.resume(returning: false)
                    return
                }
                targetClock = clock
                if !session.isRunning { session.startRunning() }
                continuation.resume(returning: session.isRunning)
            }
        }
    }

    /// Hands an already running camera to a recording. Frames only start
    /// reaching the writer once there is a clock to line them up against, so
    /// nothing from the warm-up can land in the file.
    func synchronize(to clock: CMClock) {
        queue.async { [self] in targetClock = clock }
    }

    /// Whether the camera is live, so a recording can tell a warmed-up camera
    /// from one it still has to start.
    var isRunning: Bool {
        queue.sync { session.isRunning }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if session.isRunning { session.stopRunning() }
                targetClock = nil
                continuation.resume()
            }
        }
    }

    /// The camera the person picked in the mirror. The system remembers that
    /// choice per app, so picking one there picks the one that records here
    /// and there is no second setting to keep in step.
    private static func device() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified)
        if let preferred = AVCaptureDevice.userPreferredCamera,
           discovery.devices.contains(where: { $0.uniqueID == preferred.uniqueID }) {
            return preferred
        }
        return discovery.devices.first
    }

    private func configureIfNeeded() -> Bool {
        if configured { return true }
        guard let device = Self.device(),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return false }

        let output = AVCaptureVideoDataOutput()
        // A camera frame that arrives while the last one is still being
        // written is worth less than the recording staying live.
        output.alwaysDiscardsLateVideoFrames = true

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // More than a picture-in-picture ever shows is bytes and encoder time
        // spent on pixels nobody sees; asking the camera for less leaves both
        // to the screen, which is what the recording is actually about.
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        // The track is written unflipped whatever the person chose. Mirroring
        // is a decision of the edit (`RecorderCameraOverlay.mirrored`), applied
        // when the picture is composed: pixels flipped on the way to disk
        // cannot be turned back, and a recording is reopened long after the
        // switch was set. The quick mirror under its own shortcut still flips
        // always, because a mirror you look into is not a recording.
        if let connection = output.connection(with: .video),
           connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        output.setSampleBufferDelegate(self, queue: queue)
        configured = true
        return true
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let sourceClock = session.synchronizationClock,
              let targetClock,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        else { return }
        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let targetTime = CMSyncConvertTime(sourceTime, from: sourceClock, to: targetClock)
        guard targetTime.isValid,
              let synchronized = Self.retimed(sampleBuffer, to: targetTime)
        else { return }
        onSample?(synchronized)
    }

    private static func retimed(_ sampleBuffer: CMSampleBuffer,
                                to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                        presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }
}

// MARK: - Writing

/// Writes the camera's own file for one recording: the frames as the camera
/// gave them, on the recording's timeline.
///
/// It shares the pause clock and the zero with the screen's writer, which is
/// the whole reason the two files can be laid over one another later without
/// a sync step. Everything except `finish()` runs on the session's serial
/// writer queue.
final class RecorderCameraWriter {

    private let writer: AVAssetWriter
    private let pauseClock: RecorderPauseClock
    private let timeOrigin: RecorderTimeOrigin
    private let frameRate: Int

    /// Built from the first frame rather than at init: only the camera knows
    /// how big its picture is, and a preset is a request, not an answer.
    private var input: AVAssetWriterInput?
    private var origin: Double?
    private var started = false
    private var failed = false

    /// Frames actually written, so a camera that produced nothing leaves no
    /// file behind for the editor to find and believe in.
    private(set) var frameCount = 0

    init?(url: URL,
          frameRate: Int,
          pauseClock: RecorderPauseClock,
          timeOrigin: RecorderTimeOrigin) {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        self.writer = writer
        self.pauseClock = pauseClock
        self.timeOrigin = timeOrigin
        self.frameRate = frameRate
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard !failed else { return }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentation.isValid,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if !started {
            // The screen owns the zero. A camera that woke up a moment earlier
            // must not push the screen it accompanies forward in the file, so
            // its frames are dropped until the picture has claimed one.
            guard let zero = timeOrigin.seconds,
                  presentation.seconds >= zero,
                  openFile(width: CVPixelBufferGetWidth(pixels),
                           height: CVPixelBufferGetHeight(pixels))
            else { return }
            origin = zero
            started = true
        }
        guard let origin, let input else { return }

        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let seconds = duration.isValid && !duration.isIndefinite ? max(0, duration.seconds) : 0
        guard let mapped = pauseClock.sampleTime(start: presentation.seconds,
                                                 duration: seconds,
                                                 since: origin) else { return }
        let shifted = CMTime(seconds: mapped, preferredTimescale: 600_000_000)
        guard input.isReadyForMoreMediaData,
              let retimed = Self.retimed(sampleBuffer, to: shifted) else { return }
        if input.append(retimed) {
            frameCount += 1
        } else {
            failed = true
        }
    }

    private func openFile(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let settings = Self.videoSettings(width: width,
                                          height: height,
                                          frameRate: frameRate,
                                          codec: .hevc)
        let resolved = writer.canApply(outputSettings: settings, forMediaType: .video)
            ? settings
            : Self.videoSettings(width: width,
                                 height: height,
                                 frameRate: frameRate,
                                 codec: .h264)
        guard writer.canApply(outputSettings: resolved, forMediaType: .video) else { return false }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: resolved)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        self.input = input
        return true
    }

    private static func videoSettings(width: Int,
                                      height: Int,
                                      frameRate: Int,
                                      codec: AVVideoCodecType) -> [String: Any] {
        let bitRate = RecorderSupport.averageBitRate(width: width,
                                                     height: height,
                                                     fps: frameRate,
                                                     quality: RecorderSupport.takeQuality)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalDurationKey: RecorderSupport.takeQuality.keyframeSeconds,
            // The editor scrubs this file alongside the screen's, and a file
            // without reordered frames is the one that scrubs smoothly.
            AVVideoAllowFrameReorderingKey: false,
        ]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    /// Closes the camera file. A recording whose camera never delivered a
    /// frame finishes with no file at all, which is exactly how the editor
    /// tells a recording without a face from one with an empty one.
    func finish() async -> Bool {
        guard started, !failed, frameCount > 0, let input else {
            cancel()
            return false
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }

    func cancel() {
        guard writer.status == .writing else { return }
        writer.cancelWriting()
    }

    /// A copy of the buffer carrying a new presentation time. The pixels are
    /// shared, not duplicated.
    private static func retimed(_ sampleBuffer: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }
}
