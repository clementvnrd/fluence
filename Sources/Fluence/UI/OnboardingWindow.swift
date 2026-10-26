import AppKit
import FluenceCore
import Observation
import SwiftUI

/// "Set up Fluence" (FLU-5): a first-run window that walks through the macOS permissions in
/// plain words — what each one is for, whether it is on, and one button to the right place.
///
/// Shown at launch while Accessibility or the Microphone is missing, and from the menu at
/// any time. An AppKit window rather than a SwiftUI scene so the app delegate can open it
/// at launch, where SwiftUI's `openWindow` isn't reachable.
@MainActor
final class OnboardingWindow {
    static let shared = OnboardingWindow()

    /// Dictation cannot work without these two.
    static var isNeeded: Bool {
        !Permissions.hasAccessibility || !Permissions.hasMicrophone
    }

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: DS.Onboarding.size),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Configurer Fluence"
            // FLU-12: the sidebar runs under the title bar, as in the main window.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            self.window = window
        }
        guard let window else { return }
        AppPresence.shared.becomeRegular()
        // Fresh each time it is opened, so it starts at whatever is still missing.
        if !window.isVisible {
            window.contentViewController = NSHostingController(
                rootView: OnboardingView { [weak window] in window?.close() }
            )
            window.setContentSize(DS.Onboarding.size)
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

// MARK: - Model

@MainActor
@Observable
final class OnboardingModel {
    /// Every step there can be, in order. Which ones a window shows is `steps`: a step that
    /// does not apply (FLU-29's `transcription` once Parakeet is on disk) is left out, and the
    /// numbering, the progress and Next / Back follow the list — a new step is one case here
    /// and one line in `applies`.
    enum Step: Int, CaseIterable, Identifiable {
        /// `systemAudio` is the meetings step: call detection and the call's sound (FLU-34).
        /// `transcription` downloads Parakeet with the user's consent (FLU-29).
        case accessibility, microphone, transcription, systemAudio, calendar, ready

        var id: Int { rawValue }

        var name: String {
            switch self {
            case .accessibility: "Accessibilité"
            case .microphone: "Micro"
            case .transcription: "Transcription"
            case .systemAudio: "Réunions"
            case .calendar: "Calendrier"
            case .ready: "Prêt"
            }
        }

        var isOptional: Bool { self == .systemAudio || self == .calendar }
    }

    /// The steps this window walks through, fixed when it opens: a download finishing
    /// mid-way does not make its step vanish under the user.
    let steps: [Step]

    enum Status: Equatable {
        case granted
        case missing
        /// macOS offers no way to ask; it asks the user itself on first use.
        case askedOnFirstUse
    }

    var step: Step
    private(set) var statuses: [Step: Status] = [:]

    init() {
        // Locals first: under @Observable the closures would otherwise capture `self`
        // before `step` is initialized.
        let initial = Self.readStatuses()
        statuses = initial
        let steps = Step.allCases.filter(Self.applies)
        self.steps = steps
        // Start where the work is: the first grant still missing, or the end.
        step = DevPreview.onboardingStep.flatMap(Step.init(rawValue:))
            ?? steps.first { initial[$0] == .missing } ?? .ready
    }

    /// Whether a step is part of this run of the window.
    private static func applies(_ step: Step) -> Bool {
        switch step {
        case .transcription:
            // FLU-29: only when dictation is in French or Auto, Parakeet is the engine (the
            // default there), and its model is not on disk — or its download is under way.
            let settings = Settings.shared
            let download = ParakeetDownload.shared
            download.refresh()
            if DevPreview.onboardingStep == Step.transcription.rawValue { return true }
            return settings.engine == .parakeet
                && (EngineDefault.offersParakeetStep(language: settings.dictationLanguage, parakeetReady: download.isReady)
                    || download.isDownloading)
        default:
            return true
        }
    }

    /// The steps listed in the sidebar (`ready` is the end, not a step).
    var listed: [Step] { steps.filter { $0 != .ready } }

    /// 1-based position in the list, for « Étape 2 sur 5 » and the step's circle.
    func number(of step: Step) -> Int { (listed.firstIndex(of: step) ?? 0) + 1 }

    func status(of step: Step) -> Status? { statuses[step] }

    /// Re-reads every grant. When the step on screen has just been granted, moves on by
    /// itself — the user is in System Settings and shouldn't have to come back to click Next.
    func refresh() {
        let previous = statuses
        statuses = Self.readStatuses()
        if previous[step] != .granted, statuses[step] == .granted {
            // On to the next step that still has something to say; steps already granted
            // (the microphone, often) are not worth a stop.
            step = steps.first { $0.rawValue > step.rawValue && statuses[$0] != .granted } ?? .ready
        }
    }

    func advance() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        step = steps[index + 1]
    }

    func back() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        step = steps[index - 1]
    }

    private static func readStatuses() -> [Step: Status] {
        [
            .accessibility: Permissions.hasAccessibility ? .granted : .missing,
            .microphone: Permissions.hasMicrophone ? .granted : .missing,
            // FLU-29: done once Parakeet is whole on disk.
            .transcription: ParakeetDownload.shared.refresh() ? .granted : .missing,
            .systemAudio: .askedOnFirstUse,
            .calendar: Permissions.hasCalendar ? .granted : .missing,
        ]
    }
}

// MARK: - View

/// FLU-12 (mock-up 10): the steps down a sidebar with a progress bar, the current step on
/// the right — a symbol, a title, what it is for in plain words, and one button.
private struct OnboardingView: View {
    let onDone: () -> Void

    @State private var model = OnboardingModel()
    @State private var download = ParakeetDownload.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detail
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(width: DS.Onboarding.size.width, height: DS.Onboarding.size.height)
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: DS.Onboarding.poll)
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear.frame(height: 40)
            HStack(spacing: 10) {
                AquaOrbView(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Fluence").font(.system(size: 17, weight: .bold)).foregroundStyle(DS.Color.ink)
                    Text("Premiers réglages · 2\u{00A0}min").font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
                }
            }
            .padding(.leading, 10)
            .padding(.bottom, DS.Space.wide)

            ForEach(model.listed) { step in
                Button {
                    withAnimation(DS.Motion.panel) { model.step = step }
                } label: {
                    stepRow(step)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Text(model.step == .ready ? "Terminé" : "Étape \(model.number(of: model.step)) sur \(model.listed.count)")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.Color.seam)
                        Capsule().fill(DS.Color.accent).frame(width: geometry.size.width * progress)
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, DS.Space.wide)
        }
        .padding(.horizontal, DS.Space.base)
        .frame(width: DS.Onboarding.stepColumnWidth)
        .frame(maxHeight: .infinity)
        .background(DS.Color.chassis)
        .overlay(alignment: .trailing) { Rectangle().fill(DS.Color.seam).frame(width: 1) }
    }

    private var progress: CGFloat {
        model.step == .ready ? 1 : CGFloat(model.number(of: model.step)) / CGFloat(max(1, model.listed.count))
    }

    private func stepRow(_ step: OnboardingModel.Step) -> some View {
        let isCurrent = model.step == step
        let isDone = model.status(of: step) == .granted
        return HStack(spacing: 10) {
            ZStack {
                if isDone {
                    Circle().fill(DS.Color.accent)
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                } else {
                    Circle().strokeBorder(isCurrent ? DS.Color.accent : DS.Color.seam, lineWidth: 1.5)
                    Text("\(model.number(of: step))")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(isCurrent ? DS.Color.accent : DS.Color.silkscreen)
                }
            }
            .frame(width: 20, height: 20)
            Text(step.name)
                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent || isDone ? DS.Color.ink : DS.Color.inkSecondary)
            Spacer(minLength: 0)
            if step == .transcription, let fraction = download.fraction {
                // FLU-29: the download runs on while the user moves through the other steps.
                Text(FrenchFormat.percent(fraction))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.accent)
            } else if step.isOptional {
                Text("optionnel").font(.system(size: 10, weight: .medium)).foregroundStyle(DS.Color.silkscreen)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            if isCurrent { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Color.selection) }
        }
        .contentShape(Rectangle())
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: page.symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(DS.Color.accent)
                .frame(width: 60, height: 60)
                .background(Circle().fill(DS.Color.selection))
                .padding(.bottom, DS.Space.wide)
            Text(page.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DS.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, DS.Space.snug)
            Text(page.body)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, DS.Space.wide)

            if model.step == .systemAudio {
                DetectionSwitch().padding(.bottom, DS.Space.wide)
            }

            if model.step == .transcription {
                ParakeetModelCard(download: download)
                if download.isDownloading {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").font(.system(size: 11, weight: .medium))
                        Text("Apple est utilisé en attendant.")
                    }
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .padding(.top, DS.Space.base)
                }
            } else if model.step == .ready {
                if Self.requiredGranted(model) { ShortcutLegend() }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(page.facts, id: \.text) { fact in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: fact.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DS.Color.accent)
                                .frame(width: 16)
                                .padding(.top, 1)
                            Text(fact.text).font(DS.Font.body).foregroundStyle(DS.Color.ink).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    statusLine
                }
            }
            Spacer(minLength: DS.Space.base)
            controls
        }
        .padding(.horizontal, 36)
        .padding(.top, 48)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Color.panel)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.status(of: model.step) {
        case .granted:
            GrantBadge(text: "Autorisé", isOK: true).padding(.top, DS.Space.snug)
        case .askedOnFirstUse:
            Text(model.step == .systemAudio ? Self.meetingPreparationLine : "macOS le demande à la première utilisation.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .padding(.top, DS.Space.snug)
        case .missing, nil:
            EmptyView()
        }
    }

    private var controls: some View {
        HStack(spacing: DS.Space.snug) {
            if model.step != .accessibility {
                Button("Retour") { withAnimation(DS.Motion.panel) { model.back() } }
                    .buttonStyle(.plain)
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            Spacer()
            if model.step == .ready {
                RecordPill(kind: .start, title: "Terminer", systemImage: "checkmark", action: onDone)
            } else if model.step == .transcription, model.status(of: .transcription) != .granted, !download.isDownloading {
                // FLU-29: nothing is downloaded without this click. « Plus tard » leaves Apple
                // in place; Réglages › Transcription offers the download again.
                CapButton(title: "Plus tard", height: 32) {
                    withAnimation(DS.Motion.panel) { model.advance() }
                }
                RecordPill(
                    kind: .start,
                    title: download.phase == .failed ? "Réessayer" : "Télécharger",
                    systemImage: download.phase == .failed ? "arrow.clockwise" : "arrow.down"
                ) { download.start() }
            } else if model.status(of: model.step) == .granted || model.step == .transcription {
                RecordPill(kind: .start, title: "Suivant", systemImage: "chevron.right") {
                    withAnimation(DS.Motion.panel) { model.advance() }
                }
            } else {
                // "Plus tard" moves on with the step still off, so it never looks done.
                CapButton(title: "Plus tard", height: 32) {
                    withAnimation(DS.Motion.panel) { model.advance() }
                }
                if let action = page.action {
                    RecordPill(kind: .start, title: action.title, systemImage: page.symbol) { action.run() }
                }
            }
        }
    }

    // MARK: Copy

    private struct Fact {
        var symbol: String
        var text: String
    }

    private struct Page {
        var symbol: String
        var title: String
        var body: String
        var facts: [Fact]
        var action: Action?
    }

    private struct Action {
        var title: String
        var run: () -> Void
    }

    private static let meetingSteps: Set<MeetingReadiness.Step> = [.systemAudio, .download]

    /// "Son des appels : Demandé · Modèles : 651 Mo à télécharger", live while it runs.
    private static var meetingPreparationLine: String {
        let preparation = MeetingPreparation.shared
        return "Son des appels : " + MeetingReadiness.label(preparation.state.systemAudio)
            + " · Modèles : " + MeetingReadiness.modelsLabel(preparation.state, progress: preparation.downloadProgress)
            + (preparation.failure.map { "\n" + $0 } ?? "")
    }

    private var key: String { ShortcutLabel.display(Settings.shared.pushToTalkKey.shortName) }

    private var page: Page {
        switch model.step {
        case .accessibility:
            Page(
                symbol: "accessibility",
                title: "Autoriser l'Accessibilité",
                body: "L'Accessibilité permet à Fluence de voir quand vous maintenez \(key) dans n'importe quelle app, "
                    + "et de taper vos mots là où se trouve le curseur.",
                facts: [
                    Fact(symbol: "keyboard", text: "Fluence ne guette que ses propres raccourcis et ignore toutes les autres touches."),
                    Fact(symbol: "doc.on.clipboard", text: "Sans elle, seuls les raccourcis avec une touche (⌥ Espace) marchent, et le texte reste dans le presse-papiers : collez-le avec ⌘V."),
                    Fact(symbol: "arrow.right.circle", text: "Activez Fluence dans la liste qui s'ouvre ; cette fenêtre passe à la suite toute seule."),
                ],
                action: Action(title: "Autoriser l'Accessibilité") {
                    // Puts Fluence in the list, so there is something to switch on.
                    Permissions.promptForAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            )
        case .microphone:
            Page(
                symbol: "mic.fill",
                title: "Autoriser le micro",
                body: "Fluence a besoin du micro pour vous entendre quand vous maintenez \(key). "
                    + "Votre voix est transformée en texte sur ce Mac, puis l'audio est effacé.",
                facts: [
                    Fact(symbol: "lock.fill", text: "Le son ne quitte jamais cet ordinateur."),
                    Fact(symbol: "hand.raised.fill", text: "Fluence n'écoute que pendant que vous dictez, ou pendant une réunion que vous avez acceptée."),
                    Fact(symbol: "gearshape.fill", text: "Vous pouvez retirer l'accès à tout moment dans Réglages Système."),
                ],
                action: Permissions.microphoneUndecided
                    ? Action(title: "Autoriser le micro") { Task { _ = await Permissions.requestMicrophone() } }
                    : Action(title: "Ouvrir Réglages Système") { Permissions.openMicrophoneSettings() }
            )
        case .systemAudio:
            Page(
                symbol: "person.2.wave.2",
                title: "Notes de réunion",
                body: "Quand un appel commence, Fluence peut proposer de prendre des notes. Rien n'est enregistré sans votre clic. La dictée n'en a pas besoin.",
                facts: [
                    Fact(symbol: "speaker.wave.2.fill", text: "Les autres participants sont enregistrés à partir du son de votre Mac."),
                    Fact(symbol: "doc.on.clipboard", text: "La carte de l'appel copie un avis à coller dans le chat, pour prévenir les participants."),
                    Fact(symbol: "gearshape.fill", text: "Si vous avez refusé l'accès au son, c'est dans Réglages Système qu'on le change."),
                ],
                // FLU-45: the call's sound and the models, now rather than during a first call.
                action: MeetingPreparation.shared.pendingSteps(only: Self.meetingSteps).isEmpty
                    ? Action(title: "Ouvrir Réglages Système") { Permissions.openSystemAudioSettings() }
                    : Action(title: "Préparer les réunions") {
                        Task { await MeetingPreparation.shared.prepare(only: Self.meetingSteps) }
                    }
            )
        case .transcription:
            Page(
                symbol: "waveform",
                title: "Télécharger Parakeet",
                body: "Le moteur le plus précis en français, sur ce Mac.",
                facts: [],
                action: nil
            )
        case .calendar:
            Page(
                symbol: "calendar",
                title: "Nommer vos réunions",
                body: "Avec votre calendrier, les notes de réunion reprennent le titre de l'événement et le nom des invités, "
                    + "et Fluence montre vos prochains appels. La dictée n'en a pas besoin.",
                facts: [
                    Fact(symbol: "lock.fill", text: "Le calendrier est lu sur ce Mac, et rien n'en est envoyé ailleurs."),
                    Fact(symbol: "person.2.fill", text: "Utilisé seulement pour les réunions : titres, invités, appels à venir."),
                ],
                action: Permissions.calendarUndecided
                    ? Action(title: "Autoriser le calendrier") { Task { _ = await Permissions.requestCalendar() } }
                    : Action(title: "Ouvrir Réglages Système") { Permissions.openCalendarSettings() }
            )
        case .ready:
            Page(
                symbol: Self.requiredGranted(model) ? "checkmark" : "exclamationmark",
                title: Self.requiredGranted(model) ? "Fluence est prêt" : "Presque prêt",
                body: Self.requiredGranted(model)
                    ? "Maintenez \(key) n'importe où et parlez. Ces raccourcis marchent dans toutes les apps :"
                    : "La dictée a besoin de l'Accessibilité et du micro. Revenez en arrière pour les activer, "
                        + "ou rouvrez cette fenêtre depuis la barre des menus : Configurer Fluence…",
                facts: [],
                action: nil
            )
        }
    }

    private static func requiredGranted(_ model: OnboardingModel) -> Bool {
        model.status(of: .accessibility) == .granted && model.status(of: .microphone) == .granted
    }
}

/// FLU-29 (mock-up 03): Parakeet Ultra and its size before, its progress during, « Installé »
/// after. The download is `ParakeetDownload`'s, shared with Réglages › Transcription.
private struct ParakeetModelCard: View {
    let download: ParakeetDownload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(download.phase == .failed ? DS.Color.meterAmber : DS.Color.accent)
                    .frame(width: 20)
                Text("Parakeet Ultra").font(DS.Font.bodyEmphasis).foregroundStyle(DS.Color.ink)
                Spacer(minLength: 8)
                if let fraction = download.fraction {
                    Text(DownloadProgressText.amount(fraction: fraction, totalBytes: ParakeetDownload.totalBytes))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(DS.Color.inkSecondary)
                } else if download.isReady {
                    GrantBadge(text: "Installé", isOK: true)
                } else if download.phase == .failed {
                    Text("Échec du téléchargement").font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
                } else {
                    MetaChip(text: "Environ " + FrenchFormat.bytes(ParakeetDownload.totalBytes), systemImage: "arrow.down")
                }
            }
            if let fraction = download.fraction {
                HStack(spacing: 10) {
                    DownloadBar(fraction: fraction, height: 6)
                    Text(FrenchFormat.percent(fraction))
                        .font(DS.Font.counter)
                        .foregroundStyle(DS.Color.accent)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.leading, 30)
            }
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, 14)
        .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var symbol: String {
        if download.isDownloading { return "arrow.down.circle" }
        if download.isReady { return "checkmark.circle" }
        return download.phase == .failed ? "exclamationmark.triangle.fill" : "cpu"
    }
}

/// FLU-34: the one switch for call detection, on the meetings step — the same setting as
/// Réglages › Réunions › Détecter les réunions.
private struct DetectionSwitch: View {
    @Bindable private var settings = NotetakerSettings.shared

    var body: some View {
        HStack(spacing: DS.Space.base) {
            Text("Proposer de prendre des notes quand un appel commence")
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.base)
            RowToggle(isOn: $settings.detectMeetings, label: "Proposer de prendre des notes quand un appel commence")
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.base)
        .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
