// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreImage

/// Builds everything a composer needs before the first frame is drawn: the
/// background plate, the rounded mask, and the whole pointer and zoom timeline
/// solved end to end.
///
/// Solving the motion here instead of per frame is the point of recording to a
/// master first. Smoothing that can see the future has no lag, and a zoom can
/// begin BEFORE the click that causes it, which is what makes it read as
/// deliberate rather than as a reaction.
extension RecorderComposer {

    /// `outputScale` folds the export preset into the canvas itself. The
    /// alternative, a composition renderScale, is rejected outright by the
    /// asset reader, and scaling afterwards would blur a background that was
    /// drawn sharp.
    /// `cameraSize` is the natural size of the camera track, and nil for a
    /// recording that never carried one. It is what decides whether the camera
    /// is drawn at all, so a document remembering a placement from an earlier
    /// recording cannot conjure a face onto one without a camera file.
    static func makePlan(document: RecorderEditDocument,
                         track: RecorderPointerTrack,
                         sourceSize: CGSize,
                         frameRate: Int,
                         duration: Double,
                         outputScale: CGFloat = 1,
                         cameraSize: CGSize? = nil,
                         cameraTrack: RecorderCameraTrack = RecorderCameraTrack()) -> Plan? {
        guard sourceSize.width > 0, sourceSize.height > 0, duration > 0 else { return nil }

        let style = document.resolvedBackdrop
        let aspect = document.resolvedAspect
        let hasBackdrop = style.kind != .none
        let padding = hasBackdrop ? style.padding * 0.18 : 0
        let fullCanvas = RecorderSupport.canvasSize(source: sourceSize,
                                                    padding: padding,
                                                    aspect: aspect,
                                                    cropsToAspect: !hasBackdrop)
        let scale = outputScale.isFinite ? min(1, max(0.1, outputScale)) : 1
        let canvas = scale == 1
            ? fullCanvas
            : RecorderSupport.evenSize(CGSize(width: fullCanvas.width * scale,
                                              height: fullCanvas.height * scale))
        let card = RecorderSupport.cardRect(
            canvas: canvas,
            source: sourceSize,
            padding: padding,
            fillsCanvas: !hasBackdrop && aspect != .original)

        let showsPointer = document.showsPointer && !track.samples.isEmpty
        let segments = document.activeZoomSegments(duration: duration)
        let needsCanvas = hasBackdrop || fullCanvas != RecorderSupport.evenSize(sourceSize)
        let hasCuts = !document.cuts.isEmpty
        let texts = RecorderTextOverlay.normalized(document.texts, duration: duration)
        let images = RecorderImageOverlay.normalized(document.images, duration: duration)
        let blurs = RecorderBlurRegion.normalized(document.blurs, duration: duration)
        let cameraTrackSize = cameraSize.flatMap {
            $0.width > 0 && $0.height > 0 ? $0 : nil
        }
        let camera = (cameraTrackSize != nil && document.camera.visible)
            ? document.camera.sanitized
            : nil
        // A recording with a camera track always needs a plan, even with the
        // camera turned off: without one nothing composes the two video
        // tracks, and the player would stack them however it liked.
        guard showsPointer || !segments.isEmpty || needsCanvas || hasCuts || !texts.isEmpty
            || !images.isEmpty || !blurs.isEmpty || cameraTrackSize != nil
        else { return nil }

        // Everything the pointer track knows is in the RECORDING's own time,
        // and every frame drawn is in the FINISHED video's time. The path is
        // solved once over the recording, and each output frame then reaches
        // back through the trim and the cuts to the moment it came from.
        let trim = document.trim(duration: duration)
        let cuts = RecorderTimeline.normalized(cuts: document.cuts, duration: duration)
        let outputDuration = RecorderTimeline.outputDuration(trim: trim, cuts: cuts)
        guard outputDuration > 0 else { return nil }
        let frames = max(1, Int((outputDuration * Double(max(1, frameRate))).rounded()))
        let step = 1.0 / Double(max(1, frameRate))

        let sourceRaw = RecorderMotion.resampled(track.samples,
                                                 frameRate: frameRate,
                                                 duration: duration)
        var sourcePositions = sourceRaw
        if showsPointer {
            var smoothed = RecorderMotion.smoothedPath(sourceRaw,
                                                       smoothing: document.resolvedSmoothing,
                                                       frameRate: frameRate)
            smoothed = RecorderMotion.anchored(smoothed,
                                               raw: sourceRaw,
                                               clicks: track.clicks,
                                               frameRate: frameRate)
            // Shaking the mouse to find the pointer is a gesture, not noise.
            for index in smoothed.indices
            where RecorderMotion.isShaking(sourceRaw, around: index, frameRate: frameRate) {
                smoothed[index] = sourceRaw[index]
            }
            sourcePositions = smoothed
        }
        let sourceShapes = RecorderMotion.resampledShapes(track.samples,
                                                          frameRate: frameRate,
                                                          duration: duration)
        let clusters = RecorderMotion.focusClusters(sourcePositions,
                                                    frameRate: frameRate,
                                                    zoom: RecorderSupport.sanitizedZoomAmount(
                                                        document.zoomAmount))

        // The moment of the recording each finished frame shows.
        var sourceTimes = [Double](repeating: 0, count: frames)
        for index in 0..<frames {
            sourceTimes[index] = RecorderTimeline.sourceTime(forOutput: Double(index) * step,
                                                             trim: trim,
                                                             cuts: cuts)
        }
        func sourceIndex(_ time: Double) -> Int {
            min(max(0, Int((time * Double(frameRate)).rounded())), max(0, sourcePositions.count - 1))
        }

        let sourceVisible = RecorderMotion.resampledVisibility(track.samples,
                                                               frameRate: frameRate,
                                                               duration: duration)
        var positions = [CGPoint](repeating: .zero, count: frames)
        var shapeIndex = [Int](repeating: 0, count: frames)
        var visible = [Bool](repeating: true, count: frames)
        for index in 0..<frames {
            let source = sourceIndex(sourceTimes[index])
            positions[index] = sourcePositions.indices.contains(source)
                ? sourcePositions[source] : .zero
            shapeIndex[index] = sourceShapes.indices.contains(source) ? sourceShapes[source] : 0
            visible[index] = sourceVisible.indices.contains(source) ? sourceVisible[source] : true
        }

        var zoom = [Double](repeating: 1, count: frames)
        var travel = [CGPoint](repeating: CGPoint(x: 0.5, y: 0.5), count: frames)
        if !segments.isEmpty {
            var amountTargets = [Double](repeating: 1, count: frames)
            var travelX = [Double](repeating: 0.5, count: frames)
            var travelY = [Double](repeating: 0.5, count: frames)
            // `sourceTimes` is ascending, so each lookup walks its list once
            // across the loop instead of once per frame.
            var focusCursor = 0
            for index in 0..<frames {
                let time = sourceTimes[index]
                let state = RecorderTimeline.zoomState(at: time, segments: segments)
                amountTargets[index] = 1 + (state.amount - 1) * state.progress
                // A zoom that was aimed by hand lands exactly where it was
                // put; one left on automatic follows where the pointer was
                // working, through the calmer edge-band formula.
                if let aimed = state.focus {
                    travelX[index] = RecorderMotion.travelParameter(exactFocus: Double(aimed.x),
                                                                    zoom: state.amount)
                    travelY[index] = RecorderMotion.travelParameter(exactFocus: Double(aimed.y),
                                                                    zoom: state.amount)
                } else {
                    let focus = RecorderMotion.focus(at: time,
                                                     clusters: clusters,
                                                     cursor: &focusCursor)
                    travelX[index] = RecorderMotion.travelParameter(focus: Double(focus.x))
                    travelY[index] = RecorderMotion.travelParameter(focus: Double(focus.y))
                }
            }
            // A spring carries its speed through a re-aim, so the picture
            // never restarts a movement it was already making.
            let springedAmount = RecorderMotion.springed(amountTargets, frameRate: frameRate)
            let springedX = RecorderMotion.springed(travelX, frameRate: frameRate)
            let springedY = RecorderMotion.springed(travelY, frameRate: frameRate)
            for index in 0..<frames {
                zoom[index] = max(1, springedAmount[index])
                travel[index] = CGPoint(x: springedX[index], y: springedY[index])
            }
        }

        var pointerOpacity = [Double](repeating: 1, count: frames)
        if showsPointer {
            let sourceOpacity = RecorderMotion.pointerOpacity(sourcePositions,
                                                              frameRate: frameRate)
            for index in 0..<frames {
                let source = sourceIndex(sourceTimes[index])
                pointerOpacity[index] = sourceOpacity.indices.contains(source)
                    ? sourceOpacity[source] : 1
            }
        }

        var pressScale = [Double](repeating: 1, count: frames)
        var ring = [Double](repeating: -1, count: frames)
        if showsPointer {
            var punchCursor = 0
            var ringCursor = 0
            for index in 0..<frames {
                let time = sourceTimes[index]
                pressScale[index] = RecorderMotion.pressScale(at: time,
                                                              clicks: track.clicks,
                                                              cursor: &punchCursor)
                if document.showsClickRing,
                   let progress = RecorderMotion.ringProgress(at: time,
                                                              clicks: track.clicks,
                                                              cursor: &ringCursor) {
                    ring[index] = progress
                }
            }
        }

        var textOpacity: [[Double]] = []
        if !texts.isEmpty {
            textOpacity = texts.map { overlay in
                (0..<frames).map { overlay.opacity(at: sourceTimes[$0]) }
            }
        }

        var imageOpacity: [[Double]] = []
        var imageSprites: [CGImage?] = []
        if !images.isEmpty {
            imageOpacity = images.map { overlay in
                (0..<frames).map { overlay.opacity(at: sourceTimes[$0]) }
            }
            // Read and resized here, once, at the canvas this plan draws on.
            imageSprites = images.map { RecorderImageRenderer.image(for: $0, canvas: canvas) }
        }

        var blurCovers: [[Bool]] = []
        if !blurs.isEmpty {
            blurCovers = blurs.map { region in
                (0..<frames).map { region.covers(sourceTimes[$0]) }
            }
        }

        let corner = hasBackdrop
            ? RecorderSupport.cardCorner(style.cornerRadius, cardSize: card.size)
            : 0
        let plate = needsCanvas
            ? backgroundPlate(style: style, canvas: canvas, card: card, corner: corner)
            : nil
        let mask = (needsCanvas && plate != nil)
            ? cardMask(canvas: canvas, card: card, corner: corner)
            : nil
        // Where the face goes, frame by frame. A recording whose viewer was
        // dragged replays that drag; one placed by hand in the editor holds
        // the single place it was given, which is the same list with one entry.
        var cameraRects: [CGRect] = []
        if let camera {
            let followed = camera.followsRecording
                ? cameraTrack.sanitized(duration: duration)
                : RecorderCameraTrack()
            if followed.isEmpty {
                cameraRects = [camera.rect(
                    in: card,
                    cameraAspect: cameraTrackSize.map { $0.width / $0.height } ?? 16.0 / 9.0)]
            } else {
                cameraRects = (0..<frames).map { index in
                    guard let tracked = followed.rect(at: sourceTimes[index]) else {
                        return .zero
                    }
                    return RecorderCameraOverlay.rect(fromTracked: tracked, in: card)
                }
            }
        }
        let cameraRect = cameraRects.first

        return Plan(sourceSize: RecorderSupport.evenSize(sourceSize),
                    canvasSize: canvas,
                    cardRect: card,
                    frameRate: frameRate,
                    positions: positions,
                    zoom: zoom,
                    travel: travel,
                    pressScale: pressScale,
                    ring: ring,
                    showsPointer: showsPointer,
                    pointerShapes: track.shapes,
                    pointerShapeIndex: shapeIndex,
                    pointerVisible: visible,
                    pointerOpacity: pointerOpacity,
                    // One pointer bitmap pixel is one point on screen, measured
                    // against real captures, so the whole conversion is the
                    // recorded display's own scale times what the window server
                    // and the person asked for.
                    pointerScale: CGFloat(track.displayScale)
                        * CGFloat(max(1, track.systemScale))
                        * CGFloat(RecorderSupport.sanitizedPointerSize(document.pointerSize)),
                    pointerPixelSize: (track.shapes.first?.pointSize.width ?? 28)
                        * CGFloat(track.displayScale)
                        * CGFloat(max(1, track.systemScale))
                        * CGFloat(RecorderSupport.sanitizedPointerSize(document.pointerSize)),
                    showsClickRing: document.showsClickRing,
                    plate: plate,
                    mask: mask,
                    texts: texts,
                    textOpacity: textOpacity,
                    images: images,
                    imageSprites: imageSprites,
                    imageOpacity: imageOpacity,
                    blurs: blurs,
                    blurCovers: blurCovers,
                    cameraRects: cameraRects,
                    cameraMask: cameraRect.flatMap {
                        cameraMask(size: $0.size, shape: camera?.shape ?? .rectangle)
                    })
    }

    // MARK: - Plate

    /// Background and the shadow under the recording, rendered once. Nothing
    /// in it changes frame to frame, so a per-frame composite over a finished
    /// texture is all the background ever costs.
    private static func backgroundPlate(style: ScreenshotSupport.BackdropStyle,
                                        canvas: CGSize,
                                        card: CGRect,
                                        corner: CGFloat) -> CIImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: Int(canvas.width),
                                      height: Int(canvas.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvas))
        drawFill(style: style, in: context, canvas: canvas)
        if style.blur > 0, let background = context.makeImage() {
            let bounds = CGRect(origin: .zero, size: canvas)
            let blurred = ScreenshotRenderer.blurredBackdrop(
                background, factor: CGFloat(style.blur))
            context.clear(bounds)
            context.draw(blurred, in: bounds)
        }

        if corner > 0 || style.kind != .none {
            // The recording sits on the background rather than in it, and a
            // soft shadow is the whole difference between the two.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -min(canvas.height * 0.012, 26)),
                              blur: min(canvas.height * 0.045, 90),
                              color: CGColor(gray: 0, alpha: 0.42))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.addPath(CGPath(roundedRect: card,
                                   cornerWidth: corner,
                                   cornerHeight: corner,
                                   transform: nil))
            context.fillPath()
            context.restoreGState()
        }
        return context.makeImage().map { CIImage(cgImage: $0) }
    }

    private static func drawFill(style: ScreenshotSupport.BackdropStyle,
                                 in context: CGContext,
                                 canvas: CGSize) {
        let bounds = CGRect(origin: .zero, size: canvas)
        switch style.kind {
        case .none:
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(bounds)
        case .preset:
            let stops = ScreenshotSupport.BackdropID(rawValue: style.presetID ?? "")?.stops ?? []
            drawGradient(stops, in: context, bounds: bounds)
        case .solid:
            guard let components = style.colors?.first, components.count == 3 else { return }
            context.setFillColor(CGColor(srgbRed: components[0],
                                         green: components[1],
                                         blue: components[2],
                                         alpha: 1))
            context.fill(bounds)
        case .gradient:
            let stops = (style.colors ?? []).compactMap { component -> (Double, Double, Double)? in
                guard component.count == 3 else { return nil }
                return (component[0], component[1], component[2])
            }
            drawGradient(stops.map { (red: $0.0, green: $0.1, blue: $0.2) },
                         in: context, bounds: bounds)
        case .image:
            guard let path = style.imagePath,
                  let image = loadImage(path)
            else { return }
            // Fill the canvas without distorting the picture.
            let factor = max(canvas.width / CGFloat(image.width),
                             canvas.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * factor,
                              height: CGFloat(image.height) * factor)
            context.draw(image, in: CGRect(x: (canvas.width - size.width) / 2,
                                           y: (canvas.height - size.height) / 2,
                                           width: size.width,
                                           height: size.height))
        }
    }

    private static func drawGradient(_ stops: [(red: Double, green: Double, blue: Double)],
                                     in context: CGContext,
                                     bounds: CGRect) {
        guard stops.count >= 2,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space,
                                        colors: stops.map {
                                            CGColor(srgbRed: $0.red, green: $0.green,
                                                    blue: $0.blue, alpha: 1)
                                        } as CFArray,
                                        locations: nil)
        else {
            if let first = stops.first {
                context.setFillColor(CGColor(srgbRed: first.red, green: first.green,
                                             blue: first.blue, alpha: 1))
                context.fill(bounds)
            }
            return
        }
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: bounds.minX, y: bounds.maxY),
                                   end: CGPoint(x: bounds.maxX, y: bounds.minY),
                                   options: [])
    }

    private static func loadImage(_ path: String) -> CGImage? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    /// The camera's shape alone, drawn once at its own size with its origin at
    /// zero: a face that moves during the recording is the same shape in a
    /// different place, so the mask is built once and carried, never redrawn.
    ///
    /// A circle for a talking head, a rounded rectangle otherwise: a
    /// hard-cornered box over a recording reads as a mistake, not a choice.
    private static func cameraMask(size: CGSize,
                                   shape: RecorderCameraOverlay.Shape) -> CIImage? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width >= 1, height >= 1,
              let space = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(bounds)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        switch shape {
        case .circle:
            context.addEllipse(in: bounds)
        case .rectangle:
            let corner = min(bounds.width, bounds.height) * 0.12
            context.addPath(CGPath(roundedRect: bounds,
                                   cornerWidth: corner,
                                   cornerHeight: corner,
                                   transform: nil))
        }
        context.fillPath()
        return context.makeImage().map { CIImage(cgImage: $0) }
    }

    /// White where the recording belongs, black everywhere else.
    private static func cardMask(canvas: CGSize, card: CGRect, corner: CGFloat) -> CIImage? {
        guard let space = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(data: nil,
                                      width: Int(canvas.width),
                                      height: Int(canvas.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvas))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(CGPath(roundedRect: card,
                               cornerWidth: corner,
                               cornerHeight: corner,
                               transform: nil))
        context.fillPath()
        return context.makeImage().map { CIImage(cgImage: $0) }
    }
}
