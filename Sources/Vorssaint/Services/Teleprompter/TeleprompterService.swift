// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A floating script that scrolls on its own, under the camera.
///
/// It is part of the recorder rather than a feature of its own in the hub:
/// what it needs is a window and a shortcut, and a hub entry would touch every
/// surface upstream lists features on. The window is marked as never shared,
/// so no capture, this app's or another's, can see it.
final class TeleprompterService: ObservableObject {
    static let shared = TeleprompterService()

    @Published private(set) var isVisible = false
    @Published private(set) var isPlaying = false
    /// The scroll position lives on its own object: it changes sixty times a
    /// second, and only the text may redraw that often. Buttons redrawn on
    /// every frame lost the clicks meant for them.
    let scroll = TeleprompterScroll()
    @Published var isEditing = false
    @Published private(set) var shortcutRegistrationFailed = false
    @Published private(set) var speed = TeleprompterSupport.sanitizedSpeed(
        UserDefaults.standard.integer(forKey: DefaultsKey.teleprompterSpeed)) {
        didSet { UserDefaults.standard.set(speed, forKey: DefaultsKey.teleprompterSpeed) }
    }

    /// Set while a recording chose the teleprompter: it then plays and
    /// pauses with that recording instead of with the person's keys alone.
    private(set) var followsRecording = false

    /// How far the text can scroll: its height less a margin, reported by
    /// the view once it has laid the script out.
    var scrollLimit: Double = 0

    /// Past the id range upstream hands out: its capture tools count up from
    /// 25, one per tool.
    private let hotkey = QuickToolHotkey(id: 95)
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var ticker: Timer?
    private var lastTick: CFTimeInterval?

    /// The window a screen recording has to leave out. The panel is never
    /// shared anyway; naming it too keeps the recorder's own filter honest
    /// on systems that ignore the sharing flag.
    var excludedWindowNumbers: [Int] {
        guard let number = panel?.windowNumber, number > 0, isVisible else { return [] }
        return [number]
    }

    /// Whether a point on screen falls on the teleprompter. Read on the main
    /// thread, where the event monitors that ask it run.
    func covers(screenPoint: CGPoint) -> Bool {
        guard isVisible, let panel else { return false }
        return panel.frame.contains(screenPoint)
    }

    private init() {
        hotkey.onPress = { [weak self] in self?.toggle() }
    }

    // MARK: - Preferences

    func syncWithPreferences() {
        guard AppFeature.screenRecorder.isAvailable else {
            hotkey.unregister()
            shortcutRegistrationFailed = false
            hide()
            return
        }
        let role = GlobalShortcutRole.teleprompter
        shortcutRegistrationFailed = !hotkey.sync(
            enabled: UserDefaults.standard.bool(forKey: DefaultsKey.teleprompterShortcutEnabled),
            shortcut: role.savedShortcut,
            storageKey: role.storageKey)
    }

    func suspend() {
        hotkey.unregister()
    }

    // MARK: - Window

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard AppFeature.screenRecorder.isAvailable else { return }
        let panel = ensurePanel()
        if !isVisible {
            // Opened by hand it reads at its ordinary level, whatever level
            // a picker left it at the last time.
            panel.level = Self.readingLevel
            // A script that is empty has nothing to read yet.
            isEditing = (UserDefaults.standard.string(forKey: DefaultsKey.teleprompterScript) ?? "").isEmpty
            position(panel)
        }
        isVisible = true
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        followsRecording = false
        pause()
        panel?.orderOut(nil)
        isVisible = false
    }

    // MARK: - Recordings

    /// The shielding level every picker overlay sits at; the teleprompter
    /// goes one above it so the script can be set up while an area is chosen.
    private static var pickerLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
    }

    /// Switched on in the chooser: the script comes up at once, over the
    /// picker, ready before the countdown.
    func showForPicker() {
        followsRecording = true
        show()
        panel?.level = Self.pickerLevel
    }

    /// Switched off in the chooser, or the chooser moved to a tool that has
    /// no use for it.
    func stopFollowing() {
        guard followsRecording else { return }
        followsRecording = false
        hide()
    }

    /// The picker is gone. A recording about to start keeps the script,
    /// back at an ordinary level; anything else puts it away.
    func pickerEnded(handsToRecording: Bool) {
        guard followsRecording else { return }
        panel?.level = Self.readingLevel
        if !handsToRecording { stopFollowing() }
    }

    func recordingDidStart() {
        guard followsRecording else { return }
        play()
    }

    func recordingDidPause(_ paused: Bool) {
        guard followsRecording else { return }
        paused ? pause() : play()
    }

    /// The recording ended, or never started: the script it brought along
    /// goes away with it, instead of lingering over the editor.
    func recordingDidStop() {
        guard followsRecording else { return }
        hide()
    }

    // MARK: - Scrolling

    func togglePlaying() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !isPlaying else { return }
        isEditing = false
        isPlaying = true
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func pause() {
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
        lastTick = nil
    }

    func restart() {
        scroll.offset = 0
    }

    func changeSpeed(by step: Int) {
        speed = TeleprompterSupport.sanitizedSpeed(speed + step)
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = now - (lastTick ?? now)
        lastTick = now
        scroll.offset = TeleprompterSupport.advanced(offset: scroll.offset, elapsed: elapsed,
                                                     speed: speed, limit: scrollLimit)
        // The end of the script stops the clock rather than spinning on.
        if scroll.offset >= scrollLimit { pause() }
    }

    // MARK: - Panel

    private final class TeleprompterPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// While a recording runs another app holds the focus. A click on a
    /// window that is not key would otherwise only make it key, and the
    /// button under the pointer would never hear it.
    private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// A titled window whose title bar is invisible: it looks borderless,
    /// but keeps what only a real frame gives, resizing from every edge.
    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = TeleprompterPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 220),
                                      styleMask: [.titled, .fullSizeContentView, .resizable,
                                                  .nonactivatingPanel],
                                      backing: .buffered,
                                      defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isReleasedWhenClosed = false
        // Grabbed anywhere on the script, not only by the strip on top.
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = Self.readingLevel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: 360, height: 140)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .none
        let host = FirstClickHostingView(rootView: TeleprompterView())
        // The person sizes this window; the content must not fight them.
        host.sizingOptions = []
        panel.contentView = host
        installKeyMonitor(for: panel)
        self.panel = panel
        return panel
    }

    /// Right under the camera of the screen with the pointer, so the eyes
    /// reading the script stay next to the lens. It can be moved from there.
    ///
    /// With Dynamic Island on that screen, it goes under the island's opened
    /// shape instead: the island opens on hover right there and, sitting
    /// above, took every click meant for the script's buttons.
    private func position(_ panel: NSPanel) {
        let visible = NSScreen.pointerVisibleFrame
        let size = panel.frame.size
        var top = visible.maxY - 8
        let island = NotchService.shared
        if NotchSupport.isEnabled(), visible.intersects(island.geometry.screen) {
            let reach = max(island.expandedSize.height, Self.islandCaptureControlsReach)
            top = min(top, island.geometry.screen.maxY - reach - 8)
        }
        panel.setFrameOrigin(NSPoint(x: (visible.midX - size.width / 2).rounded(),
                                     y: (top - size.height).rounded()))
    }

    /// The island's capture controls, with the recorder's row of switches,
    /// are the tallest thing it opens while a recording is being set up.
    private static let islandCaptureControlsReach: CGFloat = 240

    /// Above the island's own level, so a script dragged up under the camera
    /// still gets its clicks; below the picker's, which it only joins while
    /// an area is chosen.
    private static let readingLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

    /// Space, the arrows and Escape act on the teleprompter only while it is
    /// the key window and the script is not being typed into.
    private func installKeyMonitor(for panel: NSPanel) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, event.window === panel else { return event }
            if Int(event.keyCode) == kVK_Escape {
                self.hide()
                return nil
            }
            guard !self.isEditing else { return event }
            switch Int(event.keyCode) {
            case kVK_Space: self.togglePlaying()
            case kVK_UpArrow: self.changeSpeed(by: 1)
            case kVK_DownArrow: self.changeSpeed(by: -1)
            default: return event
            }
            return nil
        }
    }
}

/// The scroll position alone, observed only by the text that moves.
final class TeleprompterScroll: ObservableObject {
    @Published var offset: Double = 0
}
