// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation
import CoreImage
import Metal

/// Everything one frame needs, carried from the document to the compositor.
///
/// AVFoundation builds the compositor itself, so an instruction is the only
/// way to hand it the composer that knows what this particular recording
/// should look like. One instruction covers the whole recording: nothing about
/// the picture changes at instruction granularity, because the composer
/// resolves time on its own.
final class RecorderCameraCompositionInstruction: NSObject,
                                                  AVVideoCompositionInstructionProtocol,
                                                  @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    /// Read from several threads while rendering and never mutated, which is
    /// what makes handing it around this way safe.
    let composer: RecorderComposer
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID

    init(timeRange: CMTimeRange,
         composer: RecorderComposer,
         screenTrackID: CMPersistentTrackID,
         cameraTrackID: CMPersistentTrackID) {
        self.timeRange = timeRange
        self.composer = composer
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        requiredSourceTrackIDs = [NSNumber(value: screenTrackID),
                                  NSNumber(value: cameraTrackID)]
        super.init()
    }
}

/// Draws a recording that carries a camera: two pictures in, one frame out.
///
/// The stock Core Image composition hands over a single source image, which is
/// enough for everything the editor does to the screen alone. A camera is a
/// second video that has to stay a second video — movable, resizable and
/// removable after the fact — so the frames of both tracks are asked for by
/// name here and given to the same composer that draws everything else. The
/// preview and the export both run through this, so they cannot drift apart.
final class RecorderCameraCompositor: NSObject, AVVideoCompositing {

    private let renderQueue = DispatchQueue(label: "com.vorssaint.recorder.compositor",
                                            qos: .userInitiated)
    private let lock = NSLock()
    private var renderContext: AVVideoCompositionRenderContext?
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    override init() {
        // The GPU when there is one. Intermediates are not worth caching: no
        // two frames of a recording share an intermediate.
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
        super.init()
    }

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        lock.withLock { renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self else {
                request.finishCancelledRequest()
                return
            }
            self.render(request)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction
                as? RecorderCameraCompositionInstruction,
              let screen = request.sourceFrame(byTrackID: instruction.screenTrackID),
              let destination = lock.withLock({ renderContext })?.newPixelBuffer()
        else {
            request.finish(with: RecorderCompositorError.frameUnavailable)
            return
        }
        // A camera that stopped early, or started late, simply has no frame at
        // this instant: the screen is drawn on its own rather than the whole
        // export failing over a missing face.
        let camera = request.sourceFrame(byTrackID: instruction.cameraTrackID)
        let rendered = instruction.composer.render(
            CIImage(cvPixelBuffer: screen),
            camera: camera.map { CIImage(cvPixelBuffer: $0) },
            at: request.compositionTime.seconds)
        context.render(rendered,
                       to: destination,
                       bounds: CGRect(origin: .zero, size: instruction.composer.canvasSize),
                       colorSpace: colorSpace ?? CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: destination)
    }
}

enum RecorderCompositorError: Error {
    case frameUnavailable
}
