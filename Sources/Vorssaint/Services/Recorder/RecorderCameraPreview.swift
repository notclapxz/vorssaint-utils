// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation
import AppKit

/// The camera on screen, from the moment it is switched on in the picker until
/// the recording that used it ends.
///
/// It draws the very session being written, so what the person watches is what
/// the file receives, framing and all: the point of showing it before the
/// countdown is that a bad frame is fixed before it is recorded rather than
/// discovered afterwards. Like the pill, it is this app's own capture chrome:
/// the filter leaves it out of the video, because the face belongs in the
/// picture once, laid on by the editor, and not twice.
///
/// It can be dragged, and where it is dragged to is part of the recording:
/// moving the face out of the way of what is being demonstrated is something
/// people do while talking, and `RecorderCameraSampler` follows it so the
/// finished video does the same. The price is the clicks its own rectangle
/// takes from whatever is under it, which is why it starts in a corner.
final class RecorderCameraPreview {

    private var panel: NSPanel?

    /// The same picture the quick mirror shows, at the same size and with the
    /// same corners: one camera window in this app, whichever way it was
    /// opened, so nobody has to learn two of them.
    private static let size = CGSize(width: 320, height: 240)
    private static let cornerRadius: CGFloat = 14
    private static let margin: CGFloat = 24

    /// The panel itself, so a recording can follow where it is dragged to.
    var window: NSWindow? { panel }

    var excludedWindowNumbers: [Int] {
        guard let number = panel?.windowNumber, number > 0 else { return [] }
        return [number]
    }

    /// While the area is still being picked, the picker's own overlay covers
    /// every ordinary window, so the mirror has to sit above it to be seen at
    /// all. Once the picker is gone it drops back down: a window this high for
    /// a whole recording would cover a system dialog too.
    private static var pickerLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
    }

    /// Shown in the corner of the screen being recorded, where a mirror is
    /// out of the way of whatever is being demonstrated.
    func show(session: AVCaptureSession, on screen: NSScreen?, abovePicker: Bool = false) {
        guard panel == nil else { return }
        let host = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let host else { return }

        let size = Self.size
        let view = MirrorView(frame: CGRect(origin: .zero, size: size), session: session)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = abovePicker ? Self.pickerLevel : .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Draggable, like the quick mirror: where the face sits while working
        // is the person's call, and a viewer stuck in one corner is a viewer
        // covering whatever happens to be in that corner. It costs the clicks
        // it occupies, which is why it is nowhere near the middle to start.
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        let frame = host.visibleFrame
        panel.setFrameOrigin(CGPoint(x: (frame.maxX - size.width - Self.margin).rounded(),
                                     y: (frame.minY + Self.margin).rounded()))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }

    /// Called when the picker goes away and the recording begins, so the
    /// mirror stops floating over everything the system might need to show.
    func settleForRecording() {
        panel?.level = .statusBar
    }

    /// Whether a mirror is already up, so a recording that inherits a warmed
    /// camera does not build a second panel over the first.
    var isVisible: Bool { panel != nil }

    func hide() {
        guard let panel else { return }
        self.panel = nil
        (panel.contentView as? MirrorView)?.detach()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// Live camera on black with a hairline around it, cut to the same corners
    /// as the quick mirror.
    ///
    /// Flipped or not according to the person's own answer, because this is
    /// what the finished recording will look like: a viewer that mirrors while
    /// the export does not turns the setting into a surprise at the end. The
    /// quick mirror under its own shortcut always flips, and that is not an
    /// inconsistency — a mirror you look into is not a recording other people
    /// watch, and one that swaps your hands is one you have to think about.
    private final class MirrorView: NSView {
        private static let buttonSize: CGFloat = 28
        private static let buttonMargin: CGFloat = 8

        private let previewLayer: AVCaptureVideoPreviewLayer
        /// Hidden until the pointer is over the viewer. A control that sits
        /// there the whole take is a control in every glance at your own face,
        /// and the answer it changes is one people set once.
        private let mirrorButton = NSButton()
        /// The layer's connection only exists once the session has its input,
        /// which can be after this view is built, so the flip is settled again
        /// the moment the camera starts.
        private var startObserver: NSObjectProtocol?
        /// The same answer lives in Settings, so a viewer left open while it
        /// is changed there has to catch up rather than show a stale face.
        private var defaultsObserver: NSObjectProtocol?

        init(frame: NSRect, session: AVCaptureSession) {
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.cornerRadius = RecorderCameraPreview.cornerRadius
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
            layer?.backgroundColor = NSColor.black.cgColor
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = bounds
            layer?.addSublayer(previewLayer)
            addMirrorButton()
            applyMirroring()
            startObserver = NotificationCenter.default.addObserver(
                forName: .AVCaptureSessionDidStartRunning,
                object: session,
                queue: .main) { [weak self] _ in
                    self?.applyMirroring()
                }
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: UserDefaults.standard,
                queue: .main) { [weak self] _ in
                    self?.applyMirroring()
                }
        }

        private func addMirrorButton() {
            let strings = FeatureStrings.recorder(L10n.shared.language)
            mirrorButton.bezelStyle = .circular
            mirrorButton.isBordered = false
            mirrorButton.wantsLayer = true
            mirrorButton.layer?.cornerRadius = Self.buttonSize / 2
            mirrorButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            mirrorButton.contentTintColor = .white
            mirrorButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right",
                                         accessibilityDescription: strings.cameraMirrorToggle)
            mirrorButton.imagePosition = .imageOnly
            mirrorButton.toolTip = strings.cameraMirrorToggle
            mirrorButton.setAccessibilityLabel(strings.cameraMirrorToggle)
            mirrorButton.target = self
            mirrorButton.action = #selector(toggleMirroring)
            mirrorButton.isHidden = true
            addSubview(mirrorButton)
        }

        /// The viewer's own switch writes the same answer Settings writes, so
        /// the recording that follows opens already flipped the way it was
        /// watched. A switch that only changed the viewer would be the very
        /// mismatch this whole setting exists to remove.
        @objc private func toggleMirroring() {
            let defaults = UserDefaults.standard
            defaults.set(!defaults.bool(forKey: DefaultsKey.recorderCameraMirrored),
                         forKey: DefaultsKey.recorderCameraMirrored)
            applyMirroring()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds,
                                           options: [.mouseEnteredAndExited, .activeAlways],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            mirrorButton.isHidden = false
        }

        override func mouseExited(with event: NSEvent) {
            mirrorButton.isHidden = true
        }

        /// The layer's connection only exists once the session has an input,
        /// and the session is often already running by the time this panel is
        /// built, so the notification alone cannot be trusted to arrive. Every
        /// layout pass settles it too, which costs nothing and always lands.
        private func applyMirroring() {
            guard let connection = previewLayer.connection,
                  connection.isVideoMirroringSupported else { return }
            let mirrored = UserDefaults.standard.bool(forKey: DefaultsKey.recorderCameraMirrored)
            if connection.automaticallyAdjustsVideoMirroring {
                connection.automaticallyAdjustsVideoMirroring = false
            }
            if connection.isVideoMirrored != mirrored {
                connection.isVideoMirrored = mirrored
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// The layer holds the session; letting it go when the viewer closes
        /// keeps the camera's shutdown in the recorder's hands alone.
        func detach() {
            if let startObserver {
                NotificationCenter.default.removeObserver(startObserver)
                self.startObserver = nil
            }
            if let defaultsObserver {
                NotificationCenter.default.removeObserver(defaultsObserver)
                self.defaultsObserver = nil
            }
            previewLayer.removeFromSuperlayer()
        }

        deinit {
            if let startObserver {
                NotificationCenter.default.removeObserver(startObserver)
            }
            if let defaultsObserver {
                NotificationCenter.default.removeObserver(defaultsObserver)
            }
        }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
            // Bottom trailing: a face fills the middle, and the top corners are
            // where the pointer arrives from when the panel is dragged.
            mirrorButton.frame = CGRect(x: bounds.maxX - Self.buttonSize - Self.buttonMargin,
                                        y: bounds.minY + Self.buttonMargin,
                                        width: Self.buttonSize,
                                        height: Self.buttonSize)
            applyMirroring()
        }
    }
}
