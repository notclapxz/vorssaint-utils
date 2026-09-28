// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation
import Combine
import SwiftUI

/// The microphones connected right now, kept current as they come and go.
/// One list for every place voice offers a choice, so the chooser, the island
/// and Settings never disagree about what is plugged in.
final class VoiceMicrophones: ObservableObject {
    struct Microphone: Identifiable, Equatable {
        let id: String
        let name: String
    }

    @Published private(set) var connected: [Microphone] = []
    private var observers: Set<AnyCancellable> = []

    init() {
        refresh()
        let center = NotificationCenter.default
        center.publisher(for: AVCaptureDevice.wasConnectedNotification)
            .merge(with: center.publisher(for: AVCaptureDevice.wasDisconnectedNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observers)
    }

    private func refresh() {
        connected = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                     mediaType: .audio,
                                                     position: .unspecified)
            .devices
            .map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }
}

/// The microphone choice as a picker's rows: the system's input first, every
/// connected one, and a chosen one that is unplugged, which stays chosen so it
/// is used again when it comes back.
struct VoiceMicrophoneOptions: View {
    @ObservedObject var microphones: VoiceMicrophones
    let chosenID: String
    let strings: VoiceStrings

    var body: some View {
        Text(strings.systemMicrophone).tag("")
        ForEach(microphones.connected) { microphone in
            Text(microphone.name).tag(microphone.id)
        }
        if !chosenID.isEmpty, !microphones.connected.contains(where: { $0.id == chosenID }) {
            Text(strings.disconnectedMicrophone).tag(chosenID)
        }
    }
}

/// The button beside Start that drops down the microphones.
struct VoiceMicrophoneMenu: View {
    @AppStorage(DefaultsKey.voiceMicrophoneID) private var microphoneID = ""
    @StateObject private var microphones = VoiceMicrophones()
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let strings = FeatureStrings.voice(l10n.language)
        Menu {
            Picker(strings.microphoneLabel, selection: $microphoneID) {
                VoiceMicrophoneOptions(microphones: microphones, chosenID: microphoneID,
                                       strings: strings)
            }
            .pickerStyle(.inline)
        } label: {
            Label(currentName(strings), systemImage: "mic.fill")
        }
        .fixedSize()
        .help(strings.microphoneLabel)
    }

    private func currentName(_ strings: VoiceStrings) -> String {
        guard !microphoneID.isEmpty else { return strings.systemMicrophone }
        return microphones.connected.first { $0.id == microphoneID }?.name
            ?? strings.disconnectedMicrophone
    }
}
