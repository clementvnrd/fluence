import ApplicationServices
import FluenceCore
import Foundation
import FluenceDictionary
import Observation

/// Dictionary auto-learn (FLU-5): watches the text field a dictation went into, for a short
/// while, for the user correcting it.
///
/// Opt-in (`Settings.learnFromEdits`, off by default), because it means reading the field's
/// contents around the dictation for twenty seconds. What it reads stays in memory, is
/// compared and dropped; nothing is logged or written. It never reads a password field, and
/// it gives up quietly on any app that doesn't expose the field's value — Electron apps and
/// terminals mostly don't, and that is fine: this is a convenience, not a guarantee.
///
/// It never adds anything: corrections that look like names become proposals in
/// `LearnedWords`, which the user accepts or dismisses.
@MainActor
final class EditWatcher {
    static let shared = EditWatcher()

    /// How long after typing a correction still counts as one.
    private static let window: Duration = .seconds(20)
    private static let poll: Duration = .seconds(1)
    /// The paste fallback lands asynchronously, within `TextInjector`'s one-second window.
    private static let settle: Duration = .milliseconds(1_200)
    /// Past this the field is a document, not a message; diffing it every second is waste.
    private static let maxFieldLength = 50_000

    private struct Pending {
        let element: AXUIElement
        let caret: Int
        let text: String
    }

    private var pending: Pending?
    private var task: Task<Void, Never>?

    private init() {}

    /// Called just before the text is typed: notes the field and where the caret is.
    func willInsert(_ text: String) {
        // A new dictation ends the previous watch; it has already had its chance.
        task?.cancel()
        task = nil
        pending = nil

        // Before TextInjector has run once, the system default (6 s) would apply here.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXRead.appTimeout)
        guard let element = AXRead.focusedElement(), Self.isReadable(element),
              let selection = AXRead.range(element, kAXSelectedTextRangeAttribute) else { return }
        pending = Pending(element: element, caret: selection.location, text: text)
    }

    /// Called right after the text is typed: starts the watch.
    func didInsert() {
        guard let pending else { return }
        self.pending = nil
        task = Task { [weak self] in await self?.watch(pending) }
    }

    private func watch(_ pending: Pending) async {
        try? await Task.sleep(for: Self.settle)
        guard !Task.isCancelled, let baseline = Self.value(of: pending.element) else { return }

        // Our text should start at the old caret. If the app moved it (newline
        // normalisation, a replaced selection), look for it once; if it's not there exactly
        // once, there is nothing reliable to compare against.
        let length = pending.text.utf16.count
        var start = pending.caret
        if EditLearner.text(of: start..<(start + length), in: baseline) != pending.text {
            guard let found = Self.uniqueOffset(of: pending.text, in: baseline) else { return }
            start = found
        }
        var span = start..<(start + length)
        var last = baseline

        let deadline = ContinuousClock.now + Self.window
        while ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: Self.poll)
            guard let current = Self.value(of: pending.element) else { break }
            guard current != last else { continue }
            guard let moved = EditLearner.follow(span, from: last, to: current) else { return }
            span = moved
            last = current
        }

        guard last != baseline, let edited = EditLearner.text(of: span, in: last) else { return }
        let proposals = EditLearner.proposals(inserted: pending.text, edited: edited)
        if !proposals.isEmpty {
            Log.app.info("auto-learn · \(proposals.count, privacy: .public) word(s) to propose")
            LearnedWords.shared.offer(proposals)
        }
    }

    // MARK: - Accessibility

    /// A text field whose value can be read, and not a password field.
    private static func isReadable(_ element: AXUIElement) -> Bool {
        if AXRead.string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return false }
        if AXRead.string(element, kAXRoleAttribute) == "AXSecureTextField" { return false }
        guard let value = AXRead.string(element, kAXValueAttribute) else { return false }
        return value.utf16.count <= maxFieldLength
    }

    private static func value(of element: AXUIElement) -> String? {
        guard let value = AXRead.string(element, kAXValueAttribute), value.utf16.count <= maxFieldLength else {
            return nil
        }
        return value
    }

    private static func uniqueOffset(of text: String, in field: String) -> Int? {
        let nsField = field as NSString
        let first = nsField.range(of: text)
        guard first.location != NSNotFound else { return nil }
        let rest = NSRange(location: first.location + 1, length: nsField.length - first.location - 1)
        guard nsField.range(of: text, range: rest).location == NSNotFound else { return nil }
        return first.location
    }
}

/// Words the user corrected, waiting for a yes or no. In memory only: a proposal that
/// outlives the session would be a record of what the user typed.
@MainActor
@Observable
final class LearnedWords {
    static let shared = LearnedWords()

    private(set) var proposals: [EditLearner.Proposal] = []

    /// The proposal shown on the HUD capsule right after the correction (FLU-12), for
    /// `DS.HUD.offerDuration`. It stays in the main window's list after that.
    private(set) var spotlight: EditLearner.Proposal?

    /// Dismissed this session, so the same correction isn't offered twice.
    @ObservationIgnored private var dismissed: Set<String> = []
    @ObservationIgnored private var spotlightTask: Task<Void, Never>?

    private init() {}

    func offer(_ new: [EditLearner.Proposal]) {
        let known = Set(DictionaryStore.shared.entries.map { $0.write.lowercased() })
        var added: [EditLearner.Proposal] = []
        for proposal in new
        where !known.contains(proposal.written.lowercased())
            && !dismissed.contains(proposal.id)
            && !proposals.contains(proposal) {
            proposals.append(proposal)
            added.append(proposal)
        }
        if let first = added.first { show(first) }
    }

    func accept(_ proposal: EditLearner.Proposal) {
        let entry: DictionaryEntry = proposal.isCorrection
            ? .correction(hear: proposal.heard, write: proposal.written)
            : .term(proposal.written)
        DictionaryStore.shared.add(entry)
        proposals.removeAll { $0 == proposal }
        if spotlight == proposal { spotlight = nil }
    }

    func dismiss(_ proposal: EditLearner.Proposal) {
        dismissed.insert(proposal.id)
        proposals.removeAll { $0 == proposal }
        if spotlight == proposal { spotlight = nil }
    }

    /// Puts a proposal on the capsule for a while.
    func show(_ proposal: EditLearner.Proposal) {
        spotlight = proposal
        spotlightTask?.cancel()
        spotlightTask = Task { [weak self] in
            try? await Task.sleep(for: DS.HUD.offerDuration)
            guard !Task.isCancelled, let self, self.spotlight == proposal else { return }
            self.spotlight = nil
        }
    }
}
