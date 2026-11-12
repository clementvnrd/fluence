import FluenceCore
import SwiftUI

/// FLU-128 (mock-up B): the two modes at the top of Réglages › Transcription, and one line
/// saying where the voice and the text really go. « Précis » is the opt-in cloud engine
/// (FLU-113): ElevenLabs with the user's key pasted once into the Keychain, the local engine
/// as fallback. What leaves the Mac is said in one amber line, never only behind the ⓘ.
struct TranscriptionModeCards: View {
    @State private var settings = Settings.shared
    /// Bumped when the key is saved or removed: the Keychain is not observable.
    @State private var keyChanged = 0

    private static let precise = CloudProvider.elevenLabs

    var body: some View {
        let _ = keyChanged
        HStack(spacing: DS.Space.base) {
            ModeCard(systemImage: "lock.shield", title: "Privé", detail: "Tout reste sur ce Mac", isSelected: settings.cloudProvider == nil) {
                settings.cloudProvider = nil
            }
            ModeCard(systemImage: "scope", title: "Précis", detail: "La voix part chez \(Self.precise.displayName)", isSelected: settings.cloudProvider != nil) {
                settings.cloudProvider = Self.precise
            }
        }
        RouteSummary(parts: TranscriptionRoute.summary(
            local: settings.activeEngine.compared,
            cloud: settings.cloudProvider,
            hasKey: settings.cloudProvider.map { CloudKeys.shared.has($0) } ?? false,
            compareMode: settings.compareMode,
            cleanup: settings.cleanupLevel
        ))
        if let provider = settings.cloudProvider {
            SectionCard {
                CloudKeyRow(provider: provider, changed: $keyChanged)
                RowNote(text: "L'audio de vos dictées est envoyé à \(provider.displayName).", color: DS.Color.amberText)
            }
        }
    }
}

/// One of the two modes: a big card, clicked to choose it.
private struct ModeCard: View {
    let systemImage: String
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSelected ? DS.Color.accent : DS.Color.inkSecondary)
                    .frame(width: 24, height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(DS.Font.bodyEmphasis).foregroundStyle(DS.Color.ink)
                    Text(detail).font(.system(size: 11)).foregroundStyle(DS.Color.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? DS.Color.accent : DS.Color.silkscreen)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                shape
                    .fill(isSelected ? DS.Color.selection.opacity(0.55) : DS.Color.panel)
                    .overlay(shape.strokeBorder(isSelected ? DS.Color.accent : DS.Color.seam, lineWidth: isSelected ? 1.5 : 1))
                    .shadow(color: DS.Shadow.raised.color, radius: DS.Shadow.raised.radius, y: DS.Shadow.raised.y)
            )
            .contentShape(shape)
            .keyboardFocusRing(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// « Votre voix → … · Correction … · Secours … », from `TranscriptionRoute`.
private struct RouteSummary: View {
    let parts: [TranscriptionRoute.Part]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Text("·").font(DS.Font.label).foregroundStyle(DS.Color.silkscreen) }
                HStack(spacing: 5) {
                    Image(systemName: Self.symbol(part.step)).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(part.step == .missingKey ? DS.Color.meterAmber : DS.Color.accent)
                    Text(part.lead).font(DS.Font.label).foregroundStyle(DS.Color.inkSecondary)
                    if !part.target.isEmpty {
                        Text(part.target).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(part.isCloud ? DS.Color.accent : part.step == .missingKey ? DS.Color.amberText : DS.Color.ink)
                    }
                }
                .lineLimit(1)
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(DS.Color.well, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private static func symbol(_ step: TranscriptionRoute.Step) -> String {
        switch step {
        case .voice: "waveform"
        case .missingKey: "key"
        case .correction: "sparkles"
        case .fallback: "arrow.uturn.backward.circle"
        }
    }
}

/// The provider's key: a secure field until it is saved, then « •••• enregistrée » with
/// *Tester* and *Supprimer*. The key goes from the field to the Keychain, nowhere else.
private struct CloudKeyRow: View {
    let provider: CloudProvider
    /// Bumped when the key is saved or removed, so the summary line reads the Keychain again.
    @Binding var changed: Int
    @State private var draft = ""
    @State private var status: String?
    @State private var testing = false

    private static let info = "ElevenLabs (Scribe v3), avec votre propre clé. Le moteur local écoute en même temps : si le cloud est lent ou injoignable, sa transcription est collée. Les mots du dictionnaire guident la transcription."

    var body: some View {
        let _ = changed
        let saved = CloudKeys.shared.has(provider)
        SettingsRow(
            systemImage: "key",
            title: "Clé \(provider.displayName)",
            subtitle: saved ? "•••• enregistrée" + (status.map { " · " + $0 } ?? "") : status,
            info: Self.info
        ) {
            if saved {
                HStack(spacing: DS.Space.snug) {
                    CapButton(title: "Tester", height: 24, isEnabled: !testing) { test() }
                    DestructiveButton(title: "Supprimer", height: 24) { remove() }
                }
            } else {
                SecureField("Coller la clé", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(save)
            }
        }
    }

    private func save() {
        do {
            try CloudKeys.shared.save(draft, for: provider)
            draft = ""
            status = nil
            changed += 1
        } catch CloudKeys.Failure.empty {
            return
        } catch {
            // No plaintext fallback: the key is not kept anywhere else.
            Log.app.error("cloud key not saved: \(error.localizedDescription, privacy: .public)")
            Diagnostics.error("cloud.key.save", error)
            status = "Trousseau indisponible"
        }
    }

    private func remove() {
        do {
            try CloudKeys.shared.remove(provider)
            status = nil
            changed += 1
        } catch {
            Log.app.error("cloud key not removed: \(error.localizedDescription, privacy: .public)")
            Diagnostics.error("cloud.key.remove", error)
            status = "Trousseau indisponible"
        }
    }

    /// One second of silence with the saved key: says whether the provider takes it.
    private func test() {
        testing = true
        status = nil
        Task {
            let error = await CloudClient.test(provider)
            testing = false
            status = switch error {
            case nil: "Clé valide"
            case .badKey?, .noKey?: "Clé refusée"
            case .network?: "Réseau indisponible"
            default: "Service indisponible"
            }
        }
    }
}
