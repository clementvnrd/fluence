import FluenceCore
import SwiftUI

/// FLU-113: the opt-in cloud engine in Réglages › Transcription — off, Mistral or ElevenLabs,
/// a key per provider pasted once into the Keychain, and cleanup by Mistral Small. What leaves
/// the Mac is said in one amber line, never only behind the ⓘ.
struct CloudSettingsCard: View {
    @State private var settings = Settings.shared
    /// Bumped when a key is saved or removed: the Keychain is not observable.
    @State private var keysChanged = 0

    private static let choices: [CloudProvider?] = [nil] + CloudProvider.allCases

    private static let info = "Mistral (Voxtral Mini Transcribe 3) ou ElevenLabs (Scribe v3), avec votre propre clé. Le moteur local écoute en même temps : si le cloud est lent ou injoignable, sa transcription est collée. Les mots du dictionnaire guident la transcription."
    private static let cleanupInfo = "Aux niveaux Moyen et Élevé, Mistral Small nettoie le texte à la place du modèle local. S'il est lent ou refusé, le nettoyage se fait sur le Mac."

    private var hasMistralKey: Bool {
        _ = keysChanged
        return CloudKeys.shared.has(.mistral)
    }

    var body: some View {
        SectionCard {
            SettingsRow(systemImage: "cloud", title: "Moteur cloud", info: Self.info) {
                PillTabs(
                    options: Self.choices,
                    title: { $0?.displayName ?? "Désactivé" },
                    selection: .some(settings.cloudProvider),
                    small: true
                ) { settings.cloudProvider = $0 }
            }
            if let provider = settings.cloudProvider {
                RowNote(text: privacyNote(provider), color: DS.Color.amberText)
                ForEach(CloudProvider.allCases, id: \.self) { keyProvider in
                    RowDivider()
                    CloudKeyRow(provider: keyProvider, changed: $keysChanged)
                }
                RowDivider()
                SettingsRow(systemImage: "sparkles", title: "Nettoyage dans le cloud (Mistral)", info: Self.cleanupInfo) {
                    RowToggle(
                        isOn: Binding(get: { settings.cloudCleanup && hasMistralKey }, set: { settings.cloudCleanup = $0 }),
                        isEnabled: hasMistralKey
                    )
                }
            }
        }
    }

    private func privacyNote(_ provider: CloudProvider) -> String {
        let textToMistral = provider != .mistral && settings.cloudCleanup && hasMistralKey
        return "L'audio de vos dictées est envoyé à \(provider.displayName)" + (textToMistral ? ", le texte à Mistral." : ".")
    }
}

/// One provider's key: a secure field until it is saved, then « •••• enregistrée » with
/// *Tester* and *Supprimer*. The key goes from the field to the Keychain, nowhere else.
private struct CloudKeyRow: View {
    let provider: CloudProvider
    @Binding var changed: Int
    @State private var draft = ""
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        let _ = changed
        let saved = CloudKeys.shared.has(provider)
        SettingsRow(
            systemImage: "key",
            title: "Clé \(provider.displayName)",
            subtitle: saved ? "•••• enregistrée" + (status.map { " · " + $0 } ?? "") : status
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
