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
            window.title = "Set up Fluence"
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
            case .accessibility: "Accessibility"
            case .microphone: "Microphone"
            case .systemAudio: "System audio"
            case .calendar: "Calendar"
            case .ready: "Ready"
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

/// Laid out like the rest of the unit: the steps in a recessed well on the left, each with
/// a pilot lamp (lit = granted — a power lamp, not a colour code: red means recording and
/// green belongs to the meters), and the current step on a brushed panel on the right.
private struct OnboardingView: View {
    let onDone: () -> Void

    @State private var model = OnboardingModel()

    var body: some View {
        ZStack {
            DS.Color.chassis.ignoresSafeArea()

            HStack(alignment: .top, spacing: DS.Space.base) {
                stepList
                    .frame(width: DS.Onboarding.stepColumnWidth)
                detail
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

    // MARK: Steps

    private var stepList: some View {
        Well {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                ForEach(OnboardingModel.Step.allCases) { step in
                    Button {
                        withAnimation(DS.Motion.panel) { model.step = step }
                    } label: {
                        stepRow(step)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                HStack {
                    Spacer()
                    Vents(count: 5)
                }
            }
            .padding(DS.Space.snug)
            .frame(maxHeight: .infinity)
        }
    }

    private func stepRow(_ step: OnboardingModel.Step) -> some View {
        HStack(spacing: DS.Space.snug) {
            Lamp(color: DS.Color.pilot, isLit: isLit(step))
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(step.name)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.inkOnDeck)
                if step.isOptional {
                    Silkscreen(text: "Optional", color: DS.Color.inkOnDeck.opacity(DS.Library.inkDim))
                }
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.snug)
        .padding(.vertical, DS.Space.snug)
        .background {
            if model.step == step {
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(DS.Color.deck)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control)
                            .strokeBorder(DS.Color.selectionEdge, lineWidth: DS.Border.hairline)
                    )
            }
        }
        .contentShape(.rect)
    }

    /// Granted steps are lit; "Ready" lights once dictation's two requirements are on.
    private func isLit(_ step: OnboardingModel.Step) -> Bool {
        step == .ready ? Self.requiredGranted(model) : model.status(of: step) == .granted
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            HStack(alignment: .firstTextBaseline) {
                Silkscreen(text: model.step == .ready ? "Done" : "Step \(model.step.rawValue + 1) of 4", large: true)
                Spacer()
                Screw()
            }

            Text(page.title)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)

            ForEach(page.paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.step == .ready {
                if Self.requiredGranted(model) { ShortcutLegend() }
            } else {
                statusReadout
            }

            Spacer(minLength: 0)

            controls
        }
        .padding(DS.Space.wide)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BrushedPanel())
    }

    private var statusReadout: some View {
        HStack(spacing: DS.Space.snug) {
            Silkscreen(text: "Status")
            DeckWindow {
                HStack(spacing: DS.Space.snug) {
                    Lamp(color: DS.Color.pilot, isLit: model.status(of: model.step) == .granted)
                    Readout(text: statusText)
                }
                .padding(.horizontal, DS.Space.base)
                .padding(.vertical, DS.Space.snug)
            }
        }
    }

    private var statusText: String {
        switch model.status(of: model.step) {
        case .granted: "ON"
        case .missing: "NOT YET"
        case .askedOnFirstUse: "ASKED ON FIRST USE"
        case nil: ""
        }
    }

    private var controls: some View {
        HStack(spacing: DS.Space.snug) {
            if model.step != .accessibility {
                TransportKey(title: "Back", systemImage: "backward.fill", engagedColor: DS.Color.ink) {
                    withAnimation(DS.Motion.panel) { model.back() }
                }
            }
            Spacer()
            if let action = page.action, model.status(of: model.step) != .granted {
                TransportKey(title: action.title, engagedColor: DS.Color.ink) { action.run() }
            }
            if model.step == .ready {
                TransportKey(title: "Done", engagedColor: DS.Color.ink, action: onDone)
            } else {
                TransportKey(
                    title: nextTitle,
                    systemImage: "forward.fill",
                    engagedColor: DS.Color.ink
                ) {
                    withAnimation(DS.Motion.panel) { model.advance() }
                }
            }
        }
    }

    /// "Skip" when moving on would leave something off, so it never looks like the step
    /// was done.
    private var nextTitle: String {
        model.status(of: model.step) == .missing ? "Skip" : "Next"
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
                title: "Let Fluence hear the key and type for you",
                paragraphs: [
                    "Accessibility lets Fluence notice when you hold \(key) in any app, and type "
                        + "your words where the cursor is. Without it the key does nothing.",
                    "Fluence only looks for its own shortcuts and ignores every other key. "
                        + "Turn Fluence on in the list that opens; this window moves on by itself.",
                ],
                action: Action(title: "Open Settings") {
                    // Puts Fluence in the list, so there is something to switch on.
                    Permissions.promptForAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            )
        case .microphone:
            Page(
                title: "Let Fluence listen while you hold the key",
                paragraphs: [
                    "The microphone is on only while you dictate — while the key is held, or "
                        + "until you stop a hands-free dictation. Never in the background.",
                    "What you say is turned into text on this Mac. It is never sent anywhere.",
                ],
                action: Permissions.microphoneUndecided
                    ? Action(title: "Allow microphone") {
                        Task { _ = await Permissions.requestMicrophone() }
                    }
                    : Action(title: "Open Settings") { Permissions.openMicrophoneSettings() }
            )
        case .systemAudio:
            Page(
                title: "Optional: hear the other side of a call",
                paragraphs: [
                    "Meeting notes record the other people in a call from your Mac's sound. "
                        + "Dictation doesn't need this.",
                    "There is nothing to do now: macOS asks the first time you take meeting notes. "
                        + "If you said no then, this is where to change it.",
                ],
                action: Action(title: "Open Settings") { Permissions.openSystemAudioSettings() }
            )
        case .calendar:
            Page(
                title: "Optional: name your meetings",
                paragraphs: [
                    "With your calendar, meeting notes take the event's title and the names of "
                        + "the people invited. Dictation doesn't need this.",
                    "Fluence reads the calendar on this Mac, only while it takes notes.",
                ],
                action: Permissions.calendarUndecided
                    ? Action(title: "Allow calendar") {
                        Task { _ = await Permissions.requestCalendar() }
                    }
                    : Action(title: "Open Settings") { Permissions.openCalendarSettings() }
            )
        case .ready:
            Page(
                title: Self.requiredGranted(model) ? "Fluence is ready" : "Almost ready",
                paragraphs: [
                    Self.requiredGranted(model)
                        ? "Hold \(key) anywhere and talk. These work in every app:"
                        : "Dictation needs Accessibility and the microphone. Go back to switch "
                            + "them on, or reopen this window from the menu bar: Set up Fluence…",
                ],
                action: nil
            )
        }
    }

    private static func requiredGranted(_ model: OnboardingModel) -> Bool {
        model.status(of: .accessibility) == .granted && model.status(of: .microphone) == .granted
    }
}
