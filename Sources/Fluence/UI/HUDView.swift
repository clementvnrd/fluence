import FluenceCore
import SwiftUI

/// The dictation capsule above the Dock (FLU-12, mock-up 06): one capsule, one place, and
/// only its content changes — Écoute, Mains libres, Mode commande, Transcription…, the
/// auto-learn offer (the one wider state), and since FLU-29 what happened at the end: errors,
/// « Rien entendu », « Copié », « Annulé », notices (`CapsuleMessage`).
///
/// FLU-29 (Clement's choices A on the mock-ups): a model download shows as a pie in the small
/// icon slot, a reload as a turning arc; a message is a title and a detail line, both cut at
/// their end, with at most one button, in the same fixed height; the level bars only while
/// listening. Live text is still cut at its start, so the latest words stay in view.
struct HUDView: View {
    @Bindable var controller: DictationController
    /// Screenshots only (see `HUDPreview`): a fixed state instead of the controller's.
    var preview: HUDPreview?

    @State private var learned = LearnedWords.shared
    @State private var settings = Settings.shared
    @State private var download = ParakeetDownload.shared
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

    /// A model getting ready while the user talks (FLU-29, FLU-31).
    enum Preparation: Equatable {
        /// Parakeet downloading, Apple listening meanwhile: 0…1.
        case download(Double)
        /// A reload taking more than a second: the engine's name, no percentage.
        case loading(String)
    }

    enum Content: Equatable {
        case listen(text: String, preparation: Preparation?, showsLanguage: Bool)
        case handsFree(text: String)
        case command(text: String)
        case transcribing(text: String, command: Bool, preparation: Preparation?)
        /// FLU-29: what happened — errors, « Rien entendu », « Copié », « Annulé », notices.
        case message(CapsuleMessage)
        case learn(EditLearner.Proposal)
        case idle
    }

    private var content: Content {
        if let preview { return preview.content }
        switch controller.state {
        case .starting, .listening:
            if controller.isCommandMode { return .command(text: controller.transcript) }
            if controller.isHandsFree { return .handsFree(text: controller.transcript) }
            return .listen(
                text: controller.transcript,
                preparation: preparation(includingDownload: true),
                // Parakeet takes the language from the audio; the pill is for the others.
                showsLanguage: (controller.sessionEngine ?? settings.activeEngine) != .parakeet
            )
        case .finishing:
            return .transcribing(text: controller.transcript, command: controller.isCommandMode, preparation: preparation(includingDownload: false))
        case .message(let message, _):
            return .message(message)
        case .idle:
            if let proposal = learned.spotlight { return .learn(proposal) }
            return .idle
        }
    }

    /// The reload outranks the download: it is what this dictation waits on.
    private func preparation(includingDownload: Bool) -> Preparation? {
        if controller.isPreparingEngine {
            return .loading((controller.sessionEngine ?? settings.activeEngine).shortName)
        }
        if includingDownload, settings.isWaitingForParakeet, let fraction = download.fraction {
            return .download(fraction)
        }
        return nil
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

    /// The level bars: only while there is something to hear (FLU-29: hidden on results).
    private var showsWave: Bool {
        switch content {
        case .message, .learn: false
        default: true
        }
    }

    private var key: String { ShortcutLabel.display(settings.pushToTalkKey.shortName) }

    // MARK: Capsule

    @ViewBuilder
    private var capsule: some View {
        let content = self.content
        HStack(spacing: 12) {
            AquaOrbView(size: 24, isActive: isActive, isListening: isListening)
            if showsWave {
                MiniWave(isActive: isListening, level: preview == nil ? controller.level : 0.7, count: 7, maxHeight: 18)
                    .frame(width: 48)
            }
            lead(content)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(content))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(titleIsQuiet(content) ? DS.Color.inkSecondary : DS.Color.ink)
                    .lineLimit(1)
                    // Live text keeps its latest words; a message keeps its first ones.
                    .truncationMode(isMessage(content) ? .tail : .head)
                    .animation(DS.Motion.readout, value: controller.transcript)
                if let caption = caption(content) {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Color.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
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
                .shadow(color: DS.Color.aquaGlow.opacity(isActive ? 0.35 : 0.08), radius: isActive ? 20 : 10, x: 0, y: 5)
                .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
        }
    }

    private func isLearn(_ content: Content) -> Bool {
        if case .learn = content { return true }
        return false
    }

    private func isMessage(_ content: Content) -> Bool {
        if case .message = content { return true }
        return false
    }

    @ViewBuilder
    private func lead(_ content: Content) -> some View {
        switch content {
        case .listen(_, let preparation?, _), .transcribing(_, _, let preparation?):
            switch preparation {
            case .download(let fraction): DownloadPie(fraction: fraction)
            case .loading: SpinningArc(isAnimated: preview == nil)
            }
        case .handsFree:
            Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.accent)
        case .command:
            Image(systemName: "wand.and.stars").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.accent)
        case .learn:
            Image(systemName: "book.closed").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Color.accent)
        case .message(let message):
            switch message.icon {
            case .cancelled:
                Image(systemName: "xmark.circle").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Color.inkSecondary)
            case .nothingHeard:
                Image(systemName: "waveform.slash").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Color.inkSecondary)
            case .notTyped:
                Image(systemName: "text.insert").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Color.accent)
            case .warning:
                // Amber on the error glyph only: never red on the capsule (red = a meeting).
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(DS.Color.meterAmber)
            case .none:
                EmptyView()
            }
        default:
            EmptyView()
        }
    }

    private func title(_ content: Content) -> String {
        switch content {
        case .listen(let text, _, _): text.isEmpty ? "Parlez maintenant…" : text
        case .handsFree(let text): text.isEmpty ? "Mains libres · \(elapsedText)" : text
        case .command(let text): text.isEmpty ? "Réécrire la sélection…" : text
        case .transcribing(let text, let command, _):
            command ? "Application de la consigne…" : (text.isEmpty ? "Transcription…" : text)
        case .message(let message): message.title
        case .learn(let proposal): "Ajouter \(FrenchFormat.quoted(proposal.written)) au dictionnaire ?"
        case .idle: "Fluence · prêt"
        }
    }

    private func titleIsQuiet(_ content: Content) -> Bool {
        switch content {
        case .transcribing(let text, _, _): text.isEmpty
        case .message(let message): message.icon == .cancelled
        default: false
        }
    }

    private func caption(_ content: Content) -> String? {
        switch content {
        case .listen(_, let preparation?, _), .transcribing(_, _, let preparation?):
            switch preparation {
            case .download(let fraction): "Préparation du modèle… " + FrenchFormat.percent(fraction)
            case .loading(let engine): "Préparation de \(engine)…"
            }
        case .handsFree(let text):
            (text.isEmpty ? "" : "Mains libres · \(elapsedText) · ") + "Touchez \(key) pour arrêter · Échap pour annuler"
        case .command:
            "Dites la consigne, ex. \(FrenchFormat.quoted("plus court et poli"))"
        case .transcribing:
            "Sur ce Mac · \((controller.sessionEngine ?? settings.activeEngine).shortName)"
        case .message(let message):
            message.detail
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
        case .listen(_, _, let showsLanguage):
            if showsLanguage {
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
                .accessibilityLabel("Langue de dictée")
                .accessibilityValue(settings.dictationLanguage.displayName)
            }
            finishButton
        case .handsFree:
            finishButton
        case .command:
            KeyCap(text: ShortcutLabel.display(settings.commandModeKey.shortName))
        case .transcribing:
            ProgressDots()
        case .message(let message):
            // One button at most: blue for the way out of an error, grey beside a copy.
            if let action = message.action {
                SmallPill(title: action.title, primary: action.isPrimary) {
                    guard preview == nil else { return }
                    controller.performCapsuleAction()
                }
            }
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
        .accessibilityLabel("Terminer la dictée")
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
        // Never squeezed by a long message: the message is cut, the button is not.
        .fixedSize()
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

/// Screenshots of the HUD's states without dictating (FLU-12, FLU-29): only with
/// `FLUENCE_SUPPORT_DIRECTORY` set (a scratch folder) and `FLUENCE_PREVIEW_HUD` naming a state:
///
/// - `listen`, `handsFree`, `command`, `transcribing`, `cancelled`, `learn` (FLU-12);
/// - `preparingModel` (« Préparation du modèle… 42 % », `…_PROGRESS` = 0.42 by default),
///   `preparingEngine` (« Préparation de Parakeet… »);
/// - `nothingHeard` (`…_MIC` names the microphone, « MacBook Pro » by default);
/// - `notTyped` (Accessibilité non autorisée + Réglages), `notTypedAppChanged` (⌃⌘V);
/// - `errorRetry` (« La transcription a échoué » + Réessayer, `…_ENGINE` = apple, parakeet or
///   whisper), `errorMicrophone` (« Micro indisponible » + Réglages);
/// - `failure` with `…_FAILURE` naming any `DictationFailure.kind` (`microphoneLost`,
///   `engineDidNotStart`, `repeated`, `stoppedEarly`, `pasteSkipped`, `recordingExpired`…).
///
/// `FLUENCE_PREVIEW_HUD_TEXT` gives the live text; `…_HEARD` / `…_WRITTEN` the offer.
struct HUDPreview {
    let content: HUDView.Content
    var elapsed = "0:42"

    @MainActor
    static var requested: HUDPreview? {
        let env = ProcessInfo.processInfo.environment
        guard AppPaths.override != nil, let kind = env["FLUENCE_PREVIEW_HUD"] else { return nil }
        let text = env["FLUENCE_PREVIEW_HUD_TEXT"] ?? ""
        let engine = ComparedEngine(rawValue: env["FLUENCE_PREVIEW_HUD_ENGINE"] ?? "") ?? .parakeet
        switch kind {
        case "listen": return HUDPreview(content: .listen(text: text, preparation: nil, showsLanguage: true))
        case "handsFree": return HUDPreview(content: .handsFree(text: text))
        case "command": return HUDPreview(content: .command(text: text))
        case "transcribing": return HUDPreview(content: .transcribing(text: text, command: false, preparation: nil))
        case "preparingModel":
            let progress = env["FLUENCE_PREVIEW_HUD_PROGRESS"].flatMap(Double.init) ?? 0.42
            return HUDPreview(content: .listen(text: text, preparation: .download(progress), showsLanguage: true))
        case "preparingEngine":
            return HUDPreview(content: .listen(text: text, preparation: .loading(SpeechEngineChoice(engine).shortName), showsLanguage: engine != .parakeet))
        case "cancelled": return HUDPreview(content: .message(.cancelled))
        case "nothingHeard": return HUDPreview(content: .message(.nothingHeard(microphone: env["FLUENCE_PREVIEW_HUD_MIC"] ?? "MacBook Pro")))
        case "notTyped": return HUDPreview(content: .message(.notTyped(.noAccessibility, canPasteLast: false)))
        case "notTypedAppChanged": return HUDPreview(content: .message(.notTyped(.appChanged, canPasteLast: true)))
        case "errorRetry": return HUDPreview(content: .message(.failure(.engineFailed(engine, canRetry: true))))
        case "errorMicrophone": return HUDPreview(content: .message(.failure(.microphoneDenied)))
        case "failure":
            let name = env["FLUENCE_PREVIEW_HUD_FAILURE"] ?? ""
            guard let failure = DictationFailure.allCases.first(where: { $0.kind == name && $0.action != nil })
                ?? DictationFailure.allCases.first(where: { $0.kind == name })
            else { return nil }
            return HUDPreview(content: .message(.failure(failure)))
        case "learn":
            return HUDPreview(content: .learn(EditLearner.Proposal(
                heard: env["FLUENCE_PREVIEW_HUD_HEARD"] ?? "",
                written: env["FLUENCE_PREVIEW_HUD_WRITTEN"] ?? ""
            )))
        default: return nil
        }
    }
}
