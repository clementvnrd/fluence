import AppKit
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
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Configurer Fluence"
            window.isReleasedWhenClosed = false
            self.window = window
        }
        guard let window else { return }
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
    enum Step: Int, CaseIterable, Identifiable {
        case accessibility, microphone, systemAudio, calendar, ready

        var id: Int { rawValue }

        var name: String {
            switch self {
            case .accessibility: "Accessibilité"
            case .microphone: "Microphone"
            case .systemAudio: "Audio système"
            case .calendar: "Calendrier"
            case .ready: "Prêt"
            }
        }

        var isOptional: Bool { self == .systemAudio || self == .calendar }
    }

    enum Status: Equatable {
        case granted
        case missing
        /// macOS offers no way to ask; it asks the user itself on first use.
        case askedOnFirstUse
    }

    var step: Step
    private(set) var statuses: [Step: Status] = [:]

    init() {
        // A local first: under @Observable the closure would otherwise capture `self`
        // before `step` is initialized.
        let initial = Self.readStatuses()
        statuses = initial
        // Start where the work is: the first grant still missing, or the end.
        step = Step.allCases.first { initial[$0] == .missing } ?? .ready
    }

    func status(of step: Step) -> Status? { statuses[step] }

    /// Re-reads every grant. When the step on screen has just been granted, moves on by
    /// itself — the user is in System Settings and shouldn't have to come back to click Next.
    func refresh() {
        let previous = statuses
        statuses = Self.readStatuses()
        if previous[step] != .granted, statuses[step] == .granted {
            // On to the next step that still has something to say; steps already granted
            // (the microphone, often) are not worth a stop.
            step = Step.allCases.first { $0.rawValue > step.rawValue && statuses[$0] != .granted } ?? .ready
        }
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private static func readStatuses() -> [Step: Status] {
        [
            .accessibility: Permissions.hasAccessibility ? .granted : .missing,
            .microphone: Permissions.hasMicrophone ? .granted : .missing,
            .systemAudio: .askedOnFirstUse,
            .calendar: Permissions.hasCalendar ? .granted : .missing,
        ]
    }
}

// MARK: - View

/// Laid out like the main window: the orb and "Fluence" on top, the steps in a rounded card
/// on the left (a green check once granted), and the current step in a card on the right.
private struct OnboardingView: View {
    let onDone: () -> Void

    @State private var model = OnboardingModel()

    var body: some View {
        ZStack {
            DS.Color.chassis.ignoresSafeArea()

            VStack(alignment: .leading, spacing: DS.Space.base) {
                header

                HStack(alignment: .top, spacing: DS.Space.base) {
                    stepList
                        .frame(width: DS.Onboarding.stepColumnWidth)
                    detail
                }
            }
            .padding(DS.Space.roomy)
        }
        .frame(width: DS.Onboarding.size.width, height: DS.Onboarding.size.height)
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: DS.Onboarding.poll)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.base) {
            AquaOrbView(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Fluence")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(DS.Color.ink)
                Text("Configuration")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            Spacer()
            Text(model.step == .ready ? "Terminé" : "Étape \(model.step.rawValue + 1) sur 4")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(DS.Color.well, in: Capsule())
        }
    }

    // MARK: Steps

    private var stepList: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            ForEach(OnboardingModel.Step.allCases) { step in
                Button {
                    withAnimation(DS.Motion.panel) { model.step = step }
                } label: {
                    stepRow(step)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.snug)
        .frame(maxHeight: .infinity)
        .background(BrushedPanel())
    }

    private func stepRow(_ step: OnboardingModel.Step) -> some View {
        HStack(spacing: DS.Space.snug) {
            stepIcon(step)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(step.name)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                if step.isOptional {
                    Silkscreen(text: "Facultatif")
                }
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.snug)
        .padding(.vertical, DS.Space.snug)
        .background {
            if model.step == step {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(DS.Color.selection)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Color.selectionEdge, lineWidth: DS.Border.hairline)
                    )
            }
        }
        .contentShape(.rect)
    }

    /// A green check once granted; otherwise the step's number (a flag for the last one).
    private func stepIcon(_ step: OnboardingModel.Step) -> some View {
        let symbol: String
        if isLit(step) {
            symbol = "checkmark.circle.fill"
        } else if step == .ready {
            symbol = "flag.circle"
        } else {
            symbol = "\(step.rawValue + 1).circle"
        }
        return Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(isLit(step) ? DS.Color.meterGreen : DS.Color.inkSecondary)
            .frame(width: 18)
    }

    /// Granted steps are checked; "Prêt" is checked once dictation's two requirements are on.
    private func isLit(_ step: OnboardingModel.Step) -> Bool {
        step == .ready ? Self.requiredGranted(model) : model.status(of: step) == .granted
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.roomy) {
                    Text(page.title)
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(page.paragraphs, id: \.self) { paragraph in
                        Text(paragraph)
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if model.step == .ready {
                        if Self.requiredGranted(model) { ShortcutLegend() }
                    } else {
                        statusRow
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)

            controls
        }
        .padding(DS.Space.wide)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BrushedPanel())
    }

    /// Granted: a green "Autorisé" badge. Otherwise the one button to the right place.
    private var statusRow: some View {
        HStack(spacing: DS.Space.snug) {
            switch model.status(of: model.step) {
            case .granted:
                statusBadge(text: "Autorisé")
            case .askedOnFirstUse:
                Text("macOS le demande à la première utilisation")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            case .missing, nil:
                EmptyView()
            }
            if let action = page.action, model.status(of: model.step) != .granted {
                Button(action.title) { action.run() }
                    .font(DS.Font.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }

    private func statusBadge(text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(DS.Color.meterGreen)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(DS.Color.meterGreen.opacity(0.12), in: Capsule())
    }

    private var controls: some View {
        HStack(spacing: DS.Space.snug) {
            if model.step != .accessibility {
                TransportKey(title: "Retour", systemImage: "chevron.left", engagedColor: DS.Color.ink) {
                    withAnimation(DS.Motion.panel) { model.back() }
                }
            }
            Spacer()
            if model.step == .ready {
                TransportKey(title: "Terminer", isEngaged: true, engagedColor: DS.Color.ink, action: onDone)
            } else {
                TransportKey(
                    title: nextTitle,
                    systemImage: "chevron.right",
                    engagedColor: DS.Color.ink
                ) {
                    withAnimation(DS.Motion.panel) { model.advance() }
                }
            }
        }
    }

    /// "Passer" when moving on would leave something off, so it never looks like the step
    /// was done.
    private var nextTitle: String {
        model.status(of: model.step) == .missing ? "Passer" : "Suivant"
    }

    // MARK: Copy

    private struct Page {
        var title: String
        var paragraphs: [String]
        var action: Action?
    }

    private struct Action {
        var title: String
        var run: () -> Void
    }

    private var key: String { Settings.shared.pushToTalkKey.displayName }

    private var page: Page {
        switch model.step {
        case .accessibility:
            Page(
                title: "Laissez Fluence repérer la touche et écrire pour vous",
                paragraphs: [
                    "L'Accessibilité permet à Fluence de voir quand vous maintenez \(key) dans "
                        + "n'importe quelle app, et de taper vos mots là où se trouve le curseur. "
                        + "Sans elle, seuls les raccourcis avec une touche (⌥ Espace) marchent, "
                        + "et le texte reste dans le presse-papiers : collez-le avec ⌘V.",
                    "Fluence ne guette que ses propres raccourcis et ignore toutes les autres touches. "
                        + "Activez Fluence dans la liste qui s'ouvre ; cette fenêtre passe à la suite "
                        + "toute seule.",
                ],
                action: Action(title: "Autoriser…") {
                    // Puts Fluence in the list, so there is something to switch on.
                    Permissions.promptForAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            )
        case .microphone:
            Page(
                title: "Laissez Fluence écouter pendant que vous maintenez la touche",
                paragraphs: [
                    "Le micro n'est ouvert que pendant la dictée : tant que la touche est maintenue, "
                        + "ou jusqu'à ce que vous arrêtiez une dictée mains libres. Jamais en arrière-plan.",
                    "Ce que vous dites est transformé en texte sur ce Mac. Rien n'est jamais envoyé ailleurs.",
                ],
                action: Permissions.microphoneUndecided
                    ? Action(title: "Autoriser…") {
                        Task { _ = await Permissions.requestMicrophone() }
                    }
                    : Action(title: "Autoriser dans Réglages…") { Permissions.openMicrophoneSettings() }
            )
        case .systemAudio:
            Page(
                title: "Facultatif : entendre l'autre côté d'un appel",
                paragraphs: [
                    "Les notes de réunion enregistrent les autres participants d'un appel à partir "
                        + "du son de votre Mac. La dictée n'en a pas besoin.",
                    "Rien à faire maintenant : macOS le demande la première fois que vous prenez des "
                        + "notes de réunion. Si vous avez refusé, c'est ici qu'on le change.",
                ],
                action: Action(title: "Ouvrir Réglages…") { Permissions.openSystemAudioSettings() }
            )
        case .calendar:
            Page(
                title: "Facultatif : nommer vos réunions",
                paragraphs: [
                    "Avec votre calendrier, les notes de réunion reprennent le titre de l'événement "
                        + "et le nom des invités. La dictée n'en a pas besoin.",
                    "Fluence lit le calendrier de ce Mac, uniquement pendant la prise de notes.",
                ],
                action: Permissions.calendarUndecided
                    ? Action(title: "Autoriser…") {
                        Task { _ = await Permissions.requestCalendar() }
                    }
                    : Action(title: "Autoriser dans Réglages…") { Permissions.openCalendarSettings() }
            )
        case .ready:
            Page(
                title: Self.requiredGranted(model) ? "Fluence est prêt" : "Presque prêt",
                paragraphs: [
                    Self.requiredGranted(model)
                        ? "Maintenez \(key) n'importe où et parlez. Ces raccourcis marchent dans toutes les apps :"
                        : "La dictée a besoin de l'Accessibilité et du micro. Revenez en arrière pour les "
                            + "activer, ou rouvrez cette fenêtre depuis la barre des menus : Configurer Fluence…",
                ],
                action: nil
            )
        }
    }

    private static func requiredGranted(_ model: OnboardingModel) -> Bool {
        model.status(of: .accessibility) == .granted && model.status(of: .microphone) == .granted
    }
}
