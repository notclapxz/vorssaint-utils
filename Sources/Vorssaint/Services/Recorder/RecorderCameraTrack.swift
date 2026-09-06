// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import QuartzCore

/// Where the camera viewer sat, moment by moment, while the recording ran.
///
/// Dragging the viewer out of the way of what is being demonstrated is
/// something people do WHILE recording, not afterwards, and a face that
/// jumps back to a corner in the finished video throws that away. So the
/// viewer's place is recorded like the pointer's: a small track beside the
/// master, replayed by the editor, and overridable there like everything else.
///
/// Places live in the recorded area's own 0...1 space with a top-left origin,
/// the way a zoom's focus and a blur's area do, so they keep meaning the same
/// thing whatever size or shape the finished video takes.
struct RecorderCameraTrack: Codable, Equatable {

    struct Sample: Codable, Equatable {
        /// In the recording's own time, with pauses already taken out.
        var time: Double
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        var rect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    var samples: [Sample]

    init(samples: [Sample] = []) {
        self.samples = samples
    }

    var isEmpty: Bool { samples.isEmpty }

    /// Where the viewer was at `time`, interpolated between the two samples
    /// around it so a drag reads as a drag rather than as a series of jumps.
    /// Before the first sample and after the last one it simply holds still.
    func rect(at time: Double) -> CGRect? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time <= first.time { return first.rect }
        if time >= last.time { return last.rect }
        // A recording is a handful of drags, so a scan costs less than the
        // bookkeeping a binary search would need to stay correct.
        var previous = first
        for sample in samples.dropFirst() {
            if sample.time >= time {
                let span = sample.time - previous.time
                guard span > 0.0001 else { return sample.rect }
                let t = (time - previous.time) / span
                return CGRect(
                    x: previous.x + (sample.x - previous.x) * t,
                    y: previous.y + (sample.y - previous.y) * t,
                    width: previous.width + (sample.width - previous.width) * t,
                    height: previous.height + (sample.height - previous.height) * t)
            }
            previous = sample
        }
        return last.rect
    }

    /// Where a viewer standing at `viewer` belongs in a recording of `area`,
    /// both in AppKit screen coordinates counted up from the bottom.
    ///
    /// Pure on purpose: it is the whole geometry of following a window, and it
    /// is worth being able to reason about without a window to hand.
    static func place(viewer: CGRect, in area: CGRect, at time: Double) -> Sample? {
        guard area.width > 1, area.height > 1,
              viewer.width > 0, viewer.height > 0,
              time.isFinite, viewer.origin.x.isFinite, viewer.origin.y.isFinite
        else { return nil }
        // The viewer is usually parked OUTSIDE the recorded area, which is
        // exactly where it belongs while working and nowhere at all in the
        // finished video. Its place is held against the nearest edge instead,
        // so moving it aside still means something and the face stays in the
        // picture rather than being cropped away with it.
        let width = min(1, Double(viewer.width / area.width))
        let height = min(1, Double(viewer.height / area.height))
        let x = min(max(0, Double((viewer.minX - area.minX) / area.width)), 1 - width)
        // The track counts down from the top, the way the screen does.
        let y = min(max(0, Double((area.maxY - viewer.maxY) / area.height)), 1 - height)
        return Sample(time: time, x: x, y: y, width: width, height: height)
    }

    /// Whether two places are the same to the eye. A window reports moves it
    /// did not make, and a track of identical samples is a track of noise.
    static func isSamePlace(_ a: Sample, _ b: Sample) -> Bool {
        abs(a.x - b.x) < 0.0005 && abs(a.y - b.y) < 0.0005
            && abs(a.width - b.width) < 0.0005 && abs(a.height - b.height) < 0.0005
    }

    /// Drops samples a damaged or hand-edited file could carry, so a broken
    /// track costs the camera its movement and never the whole recording.
    func sanitized(duration: Double) -> RecorderCameraTrack {
        guard duration > 0 else { return RecorderCameraTrack() }
        let cleaned = samples.filter { sample in
            sample.time.isFinite && sample.time >= 0 && sample.time <= duration + 1
                && sample.x.isFinite && sample.y.isFinite
                && sample.width.isFinite && sample.height.isFinite
                && sample.width > 0.001 && sample.height > 0.001
        }
        return RecorderCameraTrack(samples: cleaned.sorted { $0.time < $1.time })
    }

    func encoded() -> Data? {
        guard !samples.isEmpty else { return nil }
        return try? JSONEncoder().encode(self)
    }

    static func decoded(_ data: Data?) -> RecorderCameraTrack {
        guard let data,
              let track = try? JSONDecoder().decode(RecorderCameraTrack.self, from: data)
        else { return RecorderCameraTrack() }
        return track
    }
}

/// Follows the camera viewer while a recording runs.
///
/// There is no polling: a window says when it moved, and a drag says so many
/// times a second on its own, which is exactly the resolution the movement
/// deserves. Nothing here exists between recordings.
final class RecorderCameraSampler {

    private let region: RecorderSupport.Region
    private let pauseClock: RecorderPauseClock

    private var observer: NSObjectProtocol?
    private weak var panel: NSWindow?
    private let lock = NSLock()
    private var samples: [RecorderCameraTrack.Sample] = []
    private var startedAt: CFTimeInterval = 0

    init(region: RecorderSupport.Region, pauseClock: RecorderPauseClock) {
        self.region = region
        self.pauseClock = pauseClock
    }

    /// Starts from where the viewer already is, so a recording whose camera is
    /// never dragged still knows where it sat the whole time.
    func start(panel: NSWindow) {
        guard observer == nil else { return }
        self.panel = panel
        startedAt = CACurrentMediaTime()
        record(at: startedAt)
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main) { [weak self] _ in
                self?.record(at: CACurrentMediaTime())
            }
    }

    /// Takes a place now, whatever the window has been saying. A viewer moved
    /// while the recording was paused reports its move inside the pause, where
    /// there is no time to record it against, so the place it ended up in is
    /// asked for again the moment recording resumes.
    func markMoved() {
        // The window's frame belongs to the main thread, and pause is toggled
        // from wherever the pill or the shortcut was used.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.markMoved() }
            return
        }
        record(at: CACurrentMediaTime())
    }

    /// No closing sample is taken: a place holds until the next one, so the
    /// last move already covers everything after it.
    func stop() -> RecorderCameraTrack {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        panel = nil
        return lock.withLock { RecorderCameraTrack(samples: samples) }
    }

    /// Reads the window and hands the geometry to the rule that decides what
    /// a place means. Everything AppKit-shaped stops here.
    private func record(at now: CFTimeInterval) {
        guard let frame = panel?.frame else { return }
        // A moment inside a pause is not a moment of the recording.
        guard let time = pauseClock.eventTime(now, since: startedAt),
              let sample = RecorderCameraTrack.place(viewer: frame,
                                                     in: region.anchorRect,
                                                     at: time)
        else { return }
        lock.withLock {
            if let last = samples.last, RecorderCameraTrack.isSamePlace(last, sample) { return }
            samples.append(sample)
        }
    }

    /// A recording torn down without a stop still lets the window go: an
    /// observer outliving its sampler would be a leak per abandoned recording.
    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
