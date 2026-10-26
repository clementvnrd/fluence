import FluenceCore
import SwiftUI

/// The dictation capsule above the Dock (FLU-12, mock-up 06): one capsule, one place, and
/// only its content changes — Écoute, Mains libres, Mode commande, Transcription…, Annulé,
/// the auto-learn offer (the one wider state), errors and notices.
struct HUDView: View {
    @Bindable var controller: DictationController
    /// Screenshots only (see `HUDPreview`): a fixed state instead of the controller's.
    var preview: HUDPreview?

    @State private var learned = LearnedWords.shared
    @State private var settings = Settings.shared
    @State private var startedAt: Date?

    var body: some View {
        ZStack {
            // Room for the soft shadow.
            Color.clear.frame(width: DS.HUD.size.width, height: DS.HUD.size.height)
            capsule
        }
        .onChange(of: controller.state.isActive) { _, isActive in
            startedAt = isActive ? Date() : nil
        }
    }

    // MARK: State

    enum Content: Equatable {
        case listen(text: String)
        case handsFree(text: String)
        case command(text: String)
        case transcribing(text: String, command: Bool)
        case cancelled
        /// The text is only on the clipboard (FLU-27).
        case copied
        case learn(EditLearner.Proposal)
        case notice(String)
        case error(String)
        case idle
    }

    private var content: Content {
        if let preview { return preview.content }
        switch controller.state {
        case .starting, .listening:
            if controller.isCommandMode { return .command(text: controller.transcript) }
            if controller.isHandsFree { return .handsFree(text: controller.transcript) }
            return .listen(text: controller.transcript)
        case .finishing:
            return .transcribing(text: controller.transcript, command: controller.isCommandMode)
        case .notice(DictationController.cancelledNotice):
            return .cancelled
        case .notice(DictationController.clipboardNotice):
            return .copied
        case .notice(let message):
            return .notice(message)
        case .error(let message):
            return .error(message)
        case .idle:
            if let proposal = learned.spotlight { return .learn(proposal) }
            return .idle
        }
    }

    private var isActive: Bool {
        switch content {
        case .listen, .handsFree, .command, .transcribing: true
        default: false
        }
    }

    private var isListening: Bool {
        switch content {
        case .listen, .handsFree, .command: true
        default: false
        }
    }

    private var key: String { ShortcutLabel.display(settings.pushToTalkKey.shortName) }

    // MARK: Capsule

    @ViewBuilder
    private var capsule: some View {
        let content = self.content
        HStack(spacing: 12) {
            AquaOrbView(size: 24, isActive: isActive, isListening: isListening)
            if case .learn = content {
                EmptyView()
            } else {
                MiniWave(isActive: isListening, level: preview == nil ? controller.level : 0.7, count: 7, maxHeight: 18)
                    .frame(width: 48)
            }
            lead(content)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(content))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(titleIsQuiet(content) ? DS.Color.inkSecondary : DS.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .animation(DS.Motion.readout, value: controller.transcript)
                if let caption = caption(content) {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Color.inkSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trail(content)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: isLearn(content) ? DS.HUD.offerWidth : DS.HUD.capsule.width, height: DS.HUD.capsule.height)
        .background {
            Capsule()
                .fill(DS.Color.panel.opacity(0.95))
                .overlay(
                    Capsule().strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.7), DS.Gradient.aqua[0].opacity(isActive ? 0.45 : 0.15), Color.white.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                )
                .shadow(color: DS.Color.focusRing.opacity(isActive ? 0.35 : 0.08), radius: isActive ? 20 : 10, x: 0, y: 5)
                .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
        }
    }

    private func isLearn(_ content: Content) -> Bool {
        if case .learn = content { return true }
        return false
    }

    @ViewBuilder
    private func lead(_ content: Content) -> some View {
        switch content {
        case .handsFree:
            Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.accent)
        case .command:
            Image(systemName: "wand.and.stars").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.accent)
        case .cancelled:
            Image(systemName: "xmark.circle").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Color.inkSecondary)
        case .copied:
            Image(systemName: "doc.on.clipboard").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Color.accent)
        case .learn:
            Image(systemName: "book.closed").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Color.accent)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(DS.Color.meterAmber)
        default:
            EmptyView()
        }
    }

    private func title(_ content: Content) -> String {
        switch content {
        case .listen(let text): text.isEmpty ? "Parlez maintenant…" : text
        case .handsFree(let text): text.isEmpty ? "Mains libres · \(elapsedText)" : text
        case .command(let text): text.isEmpty ? "Réécrire la sélection…" : text
        case .transcribing(let text, let command):
            command ? "Application de la consigne…" : (text.isEmpty ? "Transcription…" : text)
        case .cancelled: "Annulé"
        case .copied: DictationController.clipboardNotice
        case .learn(let proposal): "Ajouter \(FrenchFormat.quoted(proposal.written)) au dictionnaire ?"
        case .notice(let message), .error(let message): message
        case .idle: "Fluence · prêt"
        }
    }

    private func titleIsQuiet(_ content: Content) -> Bool {
        switch content {
        case .transcribing(let text, _): text.isEmpty
        case .cancelled: true
        default: false
        }
    }

    private func caption(_ content: Content) -> String? {
        // FLU-31: the engine is still loading; what is said is being recorded meanwhile.
        if controller.isPreparingEngine, preview == nil {
            switch content {
            case .listen, .transcribing: return "Préparation de \(settings.activeEngine.shortName)…"
            default: break
            }
        }
        return steadyCaption(content)
    }

    private func steadyCaption(_ content: Content) -> String? {
        switch content {
        case .handsFree(let text):
            (text.isEmpty ? "" : "Mains libres · \(elapsedText) · ") + "Touchez \(key) pour arrêter · Échap pour annuler"
        case .command:
            "Dites la consigne, ex. \(FrenchFormat.quoted("plus court et poli"))"
        case .transcribing:
            "Sur ce Mac · \(settings.activeEngine.shortName)"
        case .cancelled:
            "Rien n'a été collé"
        case .copied:
            "Accessibilité non autorisée"
        case .learn(let proposal):
            proposal.isCorrection
                ? "Vous avez corrigé \(FrenchFormat.quoted(proposal.heard))"
                : "Appris de vos corrections"
        default:
            nil
        }
    }

    @ViewBuilder
    private func trail(_ content: Content) -> some View {
        switch content {
        case .listen, .handsFree:
            if case .listen = content, settings.activeEngine != .parakeet {
                Button { settings.toggleLanguage() } label: {
                    Text(settings.dictationLanguage.shortDisplay)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Color.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(DS.Color.selection, in: Capsule())
                        .overlay(Capsule().strokeBorder(DS.Color.selectionEdge, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Basculer la langue (⌥L)")
            }
            finishButton
        case .command:
            KeyCap(text: ShortcutLabel.display(settings.commandModeKey.shortName))
        case .transcribing:
            ProgressDots()
        case .learn(let proposal):
            HStack(spacing: 6) {
                SmallPill(title: "Ignorer") { learned.dismiss(proposal) }
                SmallPill(title: "Ajouter", primary: true) { learned.accept(proposal) }
            }
        default:
            EmptyView()
        }
    }

    /// Ends a hands-free dictation, or a hold, and types it.
    private var finishButton: some View {
        Button {
            guard preview == nil else { return }
            if controller.isHandsFree {
                controller.stopHandsFree()
            } else {
                controller.stopButtonRecording()
            }
        } label: {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.Color.accent)
        }
        .buttonStyle(.plain)
        .help("Terminer la dictée")
    }

    private var elapsedText: String {
        if let preview { return preview.elapsed }
        guard let startedAt else { return "0:00" }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

/// "Annuler" / "Ajouter" on the offer.
private struct SmallPill: View {
    let title: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(primary ? Color.white : DS.Color.ink)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(primary ? DS.Color.accent : DS.Color.cap))
                .overlay(Capsule().strokeBorder(primary ? Color.clear : DS.Color.seam, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Three dots, fading: the transcript is being finalised.
private struct ProgressDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { timeline in
            let step = Int(timeline.date.timeIntervalSinceReferenceDate * 4) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(DS.Color.accent.opacity([1.0, 0.6, 0.3][(index - step + 3) % 3]))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.trailing, 4)
        }
    }
}

/// Screenshots of the HUD's states without dictating (FLU-12): only with
/// `FLUENCE_SUPPORT_DIRECTORY` set (a scratch folder) and `FLUENCE_PREVIEW_HUD` naming a
/// state — `listen`, `handsFree`, `command`, `transcribing`, `cancelled`, `copied` or `learn`.
/// `FLUENCE_PREVIEW_HUD_TEXT` gives the live text; `…_HEARD` / `…_WRITTEN` the offer.
struct HUDPreview {
    let content: HUDView.Content
    var elapsed = "0:42"

    @MainActor
    static var requested: HUDPreview? {
        let env = ProcessInfo.processInfo.environment
        guard AppPaths.override != nil, let kind = env["FLUENCE_PREVIEW_HUD"] else { return nil }
        let text = env["FLUENCE_PREVIEW_HUD_TEXT"] ?? ""
        switch kind {
        case "listen": return HUDPreview(content: .listen(text: text))
        case "handsFree": return HUDPreview(content: .handsFree(text: text))
        case "command": return HUDPreview(content: .command(text: text))
        case "transcribing": return HUDPreview(content: .transcribing(text: text, command: false))
        case "cancelled": return HUDPreview(content: .cancelled)
        case "copied": return HUDPreview(content: .copied)
        case "learn":
            return HUDPreview(content: .learn(EditLearner.Proposal(
                heard: env["FLUENCE_PREVIEW_HUD_HEARD"] ?? "",
                written: env["FLUENCE_PREVIEW_HUD_WRITTEN"] ?? ""
            )))
        default: return nil
        }
    }
}
