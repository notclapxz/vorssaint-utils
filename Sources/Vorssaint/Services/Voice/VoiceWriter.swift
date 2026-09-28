// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation
import CoreMedia

/// Writes the microphone alone into a small AAC file.
///
/// Mono at 64 kbps is plenty for a voice and costs about half a megabyte a
/// minute. MP3 was the alternative asked about and is not an option: macOS
/// ships no MP3 encoder, and AAC sounds better at the same size anyway.
///
/// Everything except `finish()` runs on the microphone's own queue.
final class VoiceWriter {
    static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: 48_000,
        AVEncoderBitRateKey: 64_000,
    ]

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    /// The recorder's own clock: the first sample claims the zero, and a
    /// stretch spent paused never reaches the file.
    private let pauseClock: RecorderPauseClock
    private var converter: AVAudioConverter?
    private var started = false
    private var failed = false

    /// Samples actually written, so a microphone that delivered nothing
    /// leaves no empty file behind.
    private(set) var sampleCount = 0

    init?(url: URL, pauseClock: RecorderPauseClock) {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .m4a),
              writer.canApply(outputSettings: Self.audioSettings, forMediaType: .audio)
        else { return nil }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        self.writer = writer
        self.input = input
        self.pauseClock = pauseClock
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard !failed else { return }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentation.isNumeric else { return }
        if !started {
            guard pauseClock.begin(at: presentation.seconds) else { return }
            writer.startSession(atSourceTime: .zero)
            started = true
        }
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let seconds = duration.isValid && !duration.isIndefinite ? max(0, duration.seconds) : 0
        guard let mapped = pauseClock.sampleTime(start: presentation.seconds, duration: seconds),
              input.isReadyForMoreMediaData,
              let interleaved = RecorderWriter.interleavedAudioSample(sampleBuffer,
                                                                      converter: &converter),
              let retimed = RecorderSampleTiming.retimed(
                interleaved, to: CMTime(seconds: mapped, preferredTimescale: 600_000_000))
        else { return }
        if input.append(retimed) {
            sampleCount += 1
        } else {
            failed = true
        }
    }

    func finish() async -> Bool {
        guard started, !failed, sampleCount > 0 else {
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
}
