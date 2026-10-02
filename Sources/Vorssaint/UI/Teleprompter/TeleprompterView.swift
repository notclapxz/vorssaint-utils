// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The teleprompter window: a bar of controls over the script, which is
/// either being typed or being read.
struct TeleprompterView: View {
    @ObservedObject private var service = TeleprompterService.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.teleprompterScript) private var script = ""

    private var strings: TeleprompterStrings { FeatureStrings.teleprompter(l10n.language) }
    private static let titleBarHeight: CGFloat = 28

    var body: some View {
        // The window's invisible title bar owns the top strip: every click
        // there moves the window, which is what swallowed the buttons when
        // they sat under it. The strip is a grip now and the buttons live at
        // the bottom, out of its reach.
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .frame(height: Self.titleBarHeight)
            if service.isEditing {
                editor
            } else {
                reader
            }
            Divider().overlay(Color.white.opacity(0.12))
            controls
        }
        .frame(minWidth: 360, minHeight: 140)
        .background(Color.black.opacity(0.88),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { service.restart() } label: {
                Image(systemName: "backward.end.fill")
            }
            .help(strings.restartButton)
            Button { service.togglePlaying() } label: {
                Image(systemName: service.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .disabled(script.isEmpty)
            HStack(spacing: 4) {
                Button { service.changeSpeed(by: -1) } label: { Image(systemName: "minus") }
                Text("\(strings.speedLabel) \(service.speed)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72)
                Button { service.changeSpeed(by: 1) } label: { Image(systemName: "plus") }
            }
            Spacer(minLength: 8)
            Text(strings.keysHint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Button(service.isEditing ? strings.readButton : strings.editButton) {
                service.pause()
                service.isEditing.toggle()
            }
            Button { service.hide() } label: { Image(systemName: "xmark") }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $script)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(8)
            if script.isEmpty {
                Text(strings.placeholder)
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The script moves by transform only, so scrolling costs no layout per
    /// frame. The reading line sits a third of the way down, where the eye
    /// rests under a camera, and the text may scroll until its end reaches it.
    private var reader: some View {
        TeleprompterReader(script: script, scroll: service.scroll)
    }
}

/// The moving text on its own, so the sixty redraws a second while it scrolls
/// stay inside it and never reach the buttons above.
private struct TeleprompterReader: View {
    let script: String
    @ObservedObject var scroll: TeleprompterScroll

    var body: some View {
        GeometryReader { viewport in
            Text(script)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .lineSpacing(6)
                .frame(width: max(0, viewport.size.width - 40), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { text in
                        Color.clear
                            .onAppear { TeleprompterService.shared.scrollLimit = Double(text.size.height) }
                            .onChange(of: text.size.height) { _, height in
                                TeleprompterService.shared.scrollLimit = Double(height)
                            }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, viewport.size.height / 3)
                .offset(y: -scroll.offset)
        }
        .clipped()
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black, location: 0.12),
                                   .init(color: .black, location: 0.88),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The teleprompter switch shared by the recorder's tracks and voice's panel.
/// It observes the choice itself: the chooser observing only its own state
/// would leave the switch drawn the old way after a click.
struct TeleprompterSwitch: View {
    @ObservedObject var tracks: RecorderSelectionTrackOptions
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Toggle(isOn: $tracks.teleprompter) {
            Label(FeatureStrings.teleprompter(l10n.language).title, systemImage: "text.alignleft")
        }
    }
}
