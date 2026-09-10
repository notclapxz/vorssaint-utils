// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

/// Where the camera sits on a finished recording, and how big it is.
///
/// By default it simply replays the recording: the viewer was on screen the
/// whole time and moving it out of the way is something people do while
/// talking, so that is already the answer. Placing it by hand is the override,
/// and it takes one of the same nine places a caption can take rather than a
/// dragged point. The reasons are the caption's reasons: nine places read at a
/// glance, they cover what people actually do with a face in the corner, and
/// they keep meaning the same thing when the recording is exported to another
/// shape, where an aimed point would have to be aimed again.
///
/// The size is a fraction of the recording's width, not a number of pixels,
/// so the same edit looks the same exported at any resolution.
struct RecorderCameraOverlay: Codable, Equatable {
    /// Whether the face is laid over the picture at all. A recording that
    /// carried the camera can still be finished without it, which is the whole
    /// point of keeping the two pictures apart.
    var visible: Bool
    /// Whether the camera replays where the viewer was dragged to while the
    /// recording ran. Moving it out of the way of what is being demonstrated
    /// is something people do WHILE talking, and a face that snaps back to a
    /// corner afterwards throws that work away. Placing it by hand in the
    /// editor turns this off: a decision made looking at the finished video
    /// beats one made mid sentence.
    var followsRecording: Bool
    var anchor: RecorderTextOverlay.Anchor
    /// How wide the camera is drawn, as a fraction of the recording's width.
    var size: Double
    var shape: Shape
    /// Whether the face is flipped, the way the viewer showed it for the whole
    /// take. Left alone a camera does not mirror, and that is what keeps a
    /// shirt, a whiteboard or a screen behind the person readable; it is also
    /// not what the person spent the recording looking at, so a face that
    /// swaps sides on export reads as a stranger's.
    ///
    /// It lives on the document rather than being baked in at capture time:
    /// flipping pixels on the way to disk cannot be undone, and the answer is
    /// a matter of taste that people change once they see the result.
    var mirrored: Bool

    /// A rectangle by default, because it is the shape of the viewer that was
    /// on screen the whole time: what was watched while recording is what the
    /// recording should look like. A circle is one tap away for a talking
    /// head, where it reads as a person rather than as a second screen.
    enum Shape: String, Codable, CaseIterable {
        case circle
        case rectangle
    }

    /// Big enough to read a face, small enough to leave the demonstration
    /// visible. The bounds exist so a slider can never make the camera a dot
    /// or the whole picture.
    /// Mirrored by default: it matches the viewer that was on screen while
    /// recording, so the finished video shows what was watched. Text caught on
    /// camera reads backwards, which is the cost, and the toggle is there for
    /// exactly that case.
    static let defaultMirrored = true
    static let defaultSize: Double = 0.18
    static let minimumSize: Double = 0.08
    static let maximumSize: Double = 0.45
    static let sizeRange: ClosedRange<Double> = minimumSize...maximumSize
    /// The gap between the camera and the edge of the recording, as a fraction
    /// of its shorter side. The same margin a caption keeps.
    static let margin: CGFloat = 0.05

    init(visible: Bool = true,
         followsRecording: Bool = true,
         anchor: RecorderTextOverlay.Anchor = .bottomTrailing,
         size: Double = defaultSize,
         shape: Shape = .rectangle,
         mirrored: Bool = defaultMirrored) {
        self.visible = visible
        self.followsRecording = followsRecording
        self.anchor = anchor
        self.size = size
        self.shape = shape
        self.mirrored = mirrored
    }

    /// A document written before the camera existed, or one carrying a value
    /// this build does not know, opens on the defaults rather than failing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        followsRecording = try container.decodeIfPresent(Bool.self,
                                                         forKey: .followsRecording) ?? true
        anchor = try container.decodeIfPresent(RecorderTextOverlay.Anchor.self, forKey: .anchor)
            ?? .bottomTrailing
        size = try container.decodeIfPresent(Double.self, forKey: .size) ?? Self.defaultSize
        shape = try container.decodeIfPresent(Shape.self, forKey: .shape) ?? .rectangle
        mirrored = try container.decodeIfPresent(Bool.self, forKey: .mirrored)
            ?? Self.defaultMirrored
    }

    var sanitized: RecorderCameraOverlay {
        var copy = self
        copy.size = Self.sanitizedSize(size)
        return copy
    }

    static func sanitizedSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSize }
        return min(maximumSize, max(minimumSize, value))
    }

    /// Where a place recorded by the viewer lands in the finished picture.
    /// The track holds the recorded area's own 0...1 space with a top-left
    /// origin, exactly like a blur's area, so this is the same flip.
    static func rect(fromTracked tracked: CGRect, in card: CGRect) -> CGRect {
        guard card.width > 0, card.height > 0,
              tracked.width > 0, tracked.height > 0 else { return .zero }
        return CGRect(x: card.minX + tracked.minX * card.width,
                      y: card.minY + card.height - (tracked.minY + tracked.height) * card.height,
                      width: tracked.width * card.width,
                      height: tracked.height * card.height)
    }

    /// Where the camera is drawn, in the finished picture's pixels, counted
    /// from the bottom the way Core Image does.
    ///
    /// It is placed against the recording rather than against the canvas: with
    /// a background behind the recording, a camera hung off the canvas corner
    /// floats away from the thing it belongs to.
    func rect(in card: CGRect, cameraAspect: CGFloat) -> CGRect {
        guard card.width > 0, card.height > 0 else { return .zero }
        let width = max(1, card.width * CGFloat(Self.sanitizedSize(size)))
        let aspect = cameraAspect.isFinite && cameraAspect > 0.05 ? cameraAspect : 16.0 / 9.0
        let height = shape == .circle ? width : width / aspect
        let margin = min(card.width, card.height) * Self.margin
        let point = anchor.unitPoint
        // A camera bigger than the room left for it is centred in what there
        // is, rather than pushed outside the picture by a negative span.
        let spanX = max(0, card.width - width - margin * 2)
        let spanY = max(0, card.height - height - margin * 2)
        let insetX = card.width > width ? margin : (card.width - width) / 2
        let insetY = card.height > height ? margin : (card.height - height) / 2
        let x = card.minX + insetX + spanX * point.x
        // The anchor counts down from the top, the way the screen does.
        let topY = insetY + spanY * point.y
        return CGRect(x: x, y: card.minY + card.height - topY - height,
                      width: width, height: height)
    }
}
