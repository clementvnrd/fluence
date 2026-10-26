import FluenceCore
import SwiftUI

/// « Choisir un micro » (FLU-37): the microphone list in a menu, right where the problem is
/// shown — the main window's « débranché » banner and the onboarding's « Aucun son reçu ».
/// The same choice as Réglages › Dictée › Microphone (`Settings.selectMicrophone`).
struct MicrophoneMenu: View {
    var height: CGFloat = 26
    @State private var settings = Settings.shared
    @State private var devices: [AudioInputDevice] = []

    private var isSystem: Bool {
        MicrophoneAvailability.state(selectedUID: settings.selectedMicrophoneUID, availableUIDs: []) == .system
    }

    var body: some View {
        Menu {
            Button {
                settings.selectMicrophone(nil)
            } label: {
                if isSystem { Label("Système (par défaut)", systemImage: "checkmark") } else { Text("Système (par défaut)") }
            }
            if !devices.isEmpty {
                Divider()
                ForEach(devices) { device in
                    Button {
                        settings.selectMicrophone(device)
                    } label: {
                        if settings.selectedMicrophoneUID == device.id {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
            }
        } label: {
            // CapButton's look, as a menu.
            HStack(spacing: 6) {
                Image(systemName: "mic").font(.system(size: 11, weight: .semibold))
                Text("Choisir un micro").font(DS.Font.label).lineLimit(1)
            }
            .foregroundStyle(DS.Color.ink)
            .padding(.horizontal, DS.Space.base)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(DS.Color.cap)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Color.seam, lineWidth: 1)
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // The list is read when the menu can be opened, and again on every appearance: a
        // device plugged in since shows up.
        .onAppear { devices = AudioDevices.availableInputDevices() }
        .onHover { if $0 { devices = AudioDevices.availableInputDevices() } }
    }
}
