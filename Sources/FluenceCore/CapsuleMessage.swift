import Foundation

/// What the dictation capsule says once a dictation is over, when there is something to say
/// (FLU-29): a short title, an optional detail line, at most one button.
///
/// Every string the capsule can show for a result is built here, in French, so one test can
/// read them all. Both lines are cut at their end on screen; live text, which is not a
/// message, keeps being cut at its start.
public struct CapsuleMessage: Equatable, Sendable {
    /// The small glyph in the capsule's icon slot.
    public enum Icon: Equatable, Sendable {
        case none
        /// Esc: grey circled cross.
        case cancelled
        /// Nothing rose above room tone: grey crossed-out waveform.
        case nothingHeard
        /// The text was not typed; it waits in the history and behind ⌃⌘V: accent text cursor.
        case notTyped
        /// Something failed: the amber triangle, the only amber on the capsule.
        case warning
    }

    /// The one button a message may carry.
    public enum Action: Equatable, Sendable {
        /// Runs the kept recording again (`DictationRetry`).
        case retry
        /// Réglages Système › Confidentialité › Micro.
        case microphoneSettings
        /// Réglages Système › Son, where the input device is.
        case soundSettings
        /// Réglages Système › Confidentialité › Accessibilité.
        case accessibilitySettings

        public var title: String {
            switch self {
            case .retry: "Réessayer"
            case .microphoneSettings, .soundSettings, .accessibilitySettings: "Réglages"
            }
        }

        /// Blue for the way out of an error; grey for the help offered beside a result that
        /// still worked (the text is kept).
        public var isPrimary: Bool { self != .accessibilitySettings }
    }

    public var icon: Icon
    public var title: String
    public var detail: String?
    public var action: Action?

    public init(icon: Icon, title: String, detail: String? = nil, action: Action? = nil) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.action = action
    }

    /// How long it stays: long enough to reach its button when it has one (Clement, FLU-29).
    public var duration: TimeInterval { action == nil ? Self.plainDuration : Self.actionDuration }

    public static let plainDuration: TimeInterval = 3
    public static let actionDuration: TimeInterval = 6
}

// MARK: - The messages

/// The shortcut that pastes the last dictation, through `ShortcutLabel` like every shortcut on
/// screen. It is not configurable: `HotkeyMonitor` takes whichever key gives « v » on the layout.
public enum PasteLastShortcut {
    public static var label: String { ShortcutLabel.display("⌃⌘V") }
}

extension CapsuleMessage {
    /// Esc during a dictation.
    public static let cancelled = CapsuleMessage(icon: .cancelled, title: "Annulé", detail: "Rien n'a été collé")

    /// A short notice that is not a fault (« Dernière transcription copiée. »).
    public static func notice(_ text: String) -> CapsuleMessage {
        CapsuleMessage(icon: .none, title: text)
    }

    /// The key was held, the microphone was open, and nothing in the recording was speech, or
    /// the engine heard no words. The microphone's name says which one was listening: the
    /// usual cause is the wrong input. It is the device's name, never anything said.
    public static func nothingHeard(microphone: String?) -> CapsuleMessage {
        let name = microphone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CapsuleMessage(icon: .nothingHeard, title: "Rien entendu", detail: name.isEmpty ? nil : "Micro\u{00A0}: " + name)
    }

    /// Why the text was not typed. It never goes to the clipboard (FLU-120): it stays the last
    /// dictation, in Transcriptions and behind ⌃⌘V.
    public enum NotTypedReason: Equatable, Sendable, CaseIterable {
        /// No Accessibility grant: no paste can be sent.
        case noAccessibility
        /// The app in front is not the one the key was released in (`InsertTargetPolicy`).
        case appChanged
    }

    /// - Parameter canPasteLast: ⌃⌘V is switched on and armed. It needs the Accessibility grant
    ///   too, so without the grant the capsule points to the history instead.
    public static func notTyped(_ reason: NotTypedReason, canPasteLast: Bool) -> CapsuleMessage {
        let history = "Non collé — voir Transcriptions"
        switch reason {
        case .noAccessibility:
            return CapsuleMessage(icon: .notTyped, title: history, detail: "Accessibilité non autorisée", action: .accessibilitySettings)
        case .appChanged:
            let title = canPasteLast ? "Non collé — collez avec " + PasteLastShortcut.label : history
            return CapsuleMessage(icon: .notTyped, title: title, detail: "Vous avez changé d'app")
        }
    }

    public static func failure(_ failure: DictationFailure) -> CapsuleMessage {
        CapsuleMessage(icon: .warning, title: failure.title, detail: failure.detail, action: failure.action)
    }
}

// MARK: - Failures

/// Every way a dictation can fail that the user is told about, mapped to French (FLU-29).
///
/// The engines' own error text is English and technical: it goes to the log, never here.
public enum DictationFailure: Equatable, Sendable {
    /// The microphone permission is off.
    case microphoneDenied
    /// The capture did not start (device busy or gone).
    case microphoneDidNotStart
    /// The device went away mid-recording and nothing usable was captured.
    case microphoneLost
    /// The engine did not start, and no other engine could take the recording.
    case engineDidNotStart(ComparedEngine, canRetry: Bool)
    /// The engine failed or returned nothing usable, after the automatic retry.
    case engineFailed(ComparedEngine, canRetry: Bool)
    /// The engine repeated itself (« Node.js, Node.js, … »), after the automatic retry.
    case repeated(ComparedEngine, canRetry: Bool)
    /// The engine stopped partway and what it had was typed (no recording kept to retry).
    case stoppedEarly(ComparedEngine)
    /// Something else took the clipboard just before the paste: nothing was typed.
    case pasteSkipped
    /// Réessayer, after the recording was already let go.
    case recordingExpired

    public var title: String {
        switch self {
        case .microphoneDenied, .microphoneDidNotStart: "Micro indisponible"
        case .microphoneLost: "Micro déconnecté"
        case .engineDidNotStart, .engineFailed: "La transcription a échoué"
        case .repeated: "Transcription en boucle"
        case .stoppedEarly: "Transcription incomplète"
        case .pasteSkipped: "Rien n'a été collé"
        case .recordingExpired: "Enregistrement effacé"
        }
    }

    public var detail: String {
        switch self {
        case .microphoneDenied: "Accès refusé dans Réglages Système"
        case .microphoneDidNotStart: "Le micro n'a pas démarré"
        case .microphoneLost: "Rien n'a été enregistré"
        case .engineDidNotStart(let engine, _): "\(engine.displayName) n'a pas démarré"
        case .engineFailed(let engine, _): "\(engine.displayName) n'a pas répondu"
        case .repeated: "Rien n'a été collé"
        case .stoppedEarly(let engine): "\(engine.displayName) s'est arrêté avant la fin"
        case .pasteSkipped: "Le presse-papiers a changé"
        case .recordingExpired: "Gardé 1\u{00A0}min seulement"
        }
    }

    /// One action at most; none only when nothing would help.
    public var action: CapsuleMessage.Action? {
        switch self {
        case .microphoneDenied: .microphoneSettings
        case .microphoneDidNotStart, .microphoneLost: .soundSettings
        case .engineDidNotStart(_, let canRetry), .engineFailed(_, let canRetry), .repeated(_, let canRetry):
            canRetry ? .retry : nil
        case .stoppedEarly, .pasteSkipped, .recordingExpired: nil
        }
    }

    /// For the log and diagnostics: fixed words, never a transcript.
    public var kind: String {
        switch self {
        case .microphoneDenied: "microphoneDenied"
        case .microphoneDidNotStart: "microphoneDidNotStart"
        case .microphoneLost: "microphoneLost"
        case .engineDidNotStart: "engineDidNotStart"
        case .engineFailed: "engineFailed"
        case .repeated: "repeated"
        case .stoppedEarly: "stoppedEarly"
        case .pasteSkipped: "pasteSkipped"
        case .recordingExpired: "recordingExpired"
        }
    }

    /// Every case, each engine where one applies: what the test reads.
    public static var allCases: [DictationFailure] {
        var cases: [DictationFailure] = [.microphoneDenied, .microphoneDidNotStart, .microphoneLost, .pasteSkipped, .recordingExpired]
        for engine in ComparedEngine.allCases {
            for canRetry in [true, false] {
                cases += [.engineDidNotStart(engine, canRetry: canRetry), .engineFailed(engine, canRetry: canRetry), .repeated(engine, canRetry: canRetry)]
            }
            cases.append(.stoppedEarly(engine))
        }
        return cases
    }
}

// MARK: - Timing

/// The capsule's life once a dictation has ended (FLU-29): which message is up, and when it
/// goes. A pure state machine — state and event in, state out — so the timing is tested.
///
/// A message stays `CapsuleMessage.duration` (3 s, 6 s with a button), and its clock stops
/// while the pointer is on the capsule. Each message shown gets a new identity, and only a
/// timer carrying that identity can take it down: the same text shown twice in a row is two
/// messages, and the first one's timer no longer cuts the second one short.
public struct CapsuleTimeline: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case hidden
        /// A dictation is running: the capsule shows it, no message.
        case dictating
        case message(CapsuleMessage, id: UInt64)
    }

    public enum Event: Equatable, Sendable {
        case dictationStarted
        /// Ended with nothing to say.
        case dictationEnded
        case show(CapsuleMessage)
        case hover(Bool)
        /// The timer armed for message `id` fired.
        case timerFired(id: UInt64)
        /// The message's button was pressed.
        case actionTaken(id: UInt64)
    }

    /// After the pointer leaves, a message whose time ran out while it was read gets this much
    /// more, rather than vanishing the instant the pointer moves.
    public static let graceAfterHover: TimeInterval = 1

    public private(set) var phase: Phase = .hidden
    public private(set) var isHovered = false
    private var lastID: UInt64 = 0
    /// Time the message has left, counted from `runningSince`.
    private var remaining: TimeInterval = 0
    /// Nil while paused (hovered) or with no message up.
    private var runningSince: TimeInterval?

    public init() {}

    public var message: CapsuleMessage? {
        if case .message(let message, _) = phase { return message }
        return nil
    }

    public var messageID: UInt64? {
        if case .message(_, let id) = phase { return id }
        return nil
    }

    /// When the message on screen should go; nil while the pointer holds it, or with no message.
    public var deadline: TimeInterval? {
        guard messageID != nil, let runningSince else { return nil }
        return runningSince + remaining
    }

    public mutating func handle(_ event: Event, at now: TimeInterval) {
        switch event {
        case .dictationStarted:
            phase = .dictating
            runningSince = nil
        case .dictationEnded:
            phase = .hidden
            runningSince = nil
        case .show(let message):
            lastID &+= 1
            phase = .message(message, id: lastID)
            remaining = message.duration
            runningSince = isHovered ? nil : now
        case .hover(let inside):
            guard inside != isHovered else { return }
            isHovered = inside
            guard messageID != nil else { return }
            if inside, let since = runningSince {
                remaining = max(0, remaining - (now - since))
                runningSince = nil
            } else if !inside {
                remaining = max(remaining, Self.graceAfterHover)
                runningSince = now
            }
        case .timerFired(let id):
            guard messageID == id, let deadline, now >= deadline else { return }
            phase = .hidden
            runningSince = nil
        case .actionTaken(let id):
            guard messageID == id else { return }
            phase = .hidden
            runningSince = nil
        }
    }
}

// MARK: - Where the text goes

/// Text is typed only into the app that was in front when the key came up (FLU-29). Anything
/// else — the user switched apps while the engine worked — keeps the text for ⌃⌘V (never on
/// the clipboard, FLU-120), and the capsule says so, instead of typing into whatever has focus.
public enum InsertTargetPolicy {
    /// An app, by process: two windows of one app are one target, a relaunched app is not.
    public struct App: Equatable, Sendable {
        public var processID: Int32
        public var bundleID: String?

        public init(processID: Int32, bundleID: String?) {
            self.processID = processID
            self.bundleID = bundleID
        }
    }

    public enum Decision: Equatable, Sendable {
        case insert
        case keep(CapsuleMessage.NotTypedReason)
    }

    /// - Parameters:
    ///   - target: the app in front at release (for a dictation started from Fluence's own
    ///     window, the app it hands the text back to); nil when none could be read.
    ///   - frontmost: the app in front now, just before typing.
    public static func decide(target: App?, frontmost: App?, hasAccessibility: Bool) -> Decision {
        // Without the grant no paste can land anywhere: that is the thing to fix first.
        guard hasAccessibility else { return .keep(.noAccessibility) }
        // Nothing was in front at release (the login window, a space switch): nothing to
        // compare with, so the text goes where it always went.
        guard let target else { return .insert }
        guard let frontmost, frontmost.processID == target.processID else { return .keep(.appChanged) }
        return .insert
    }
}

// MARK: - Retrying a recording

/// What happens to a recording whose transcription failed (FLU-29).
///
/// The recording stays in memory — never on disk — for `keepSeconds` after the dictation,
/// for one automatic retry and then the capsule's *Réessayer*. A successful dictation drops it
/// at once.
public enum DictationRetry {
    public static let keepSeconds: TimeInterval = 60
    /// Longer recordings are not kept: ten minutes of 16 kHz audio is already ~38 MB.
    public static let maxKeptAudioSeconds: TimeInterval = 10 * 60

    public enum Trigger: Equatable, Sendable {
        /// The engine could not be started (model missing or not loadable, language).
        case didNotStart
        /// The engine threw, or ended with an error.
        case failed
        /// The engine repeated itself (`TranscriptHealth.isDegenerate`).
        case repeated
    }

    public static func shouldKeep(audioSeconds: TimeInterval) -> Bool {
        audioSeconds.isFinite && audioSeconds > 0 && audioSeconds <= maxKeptAudioSeconds
    }

    /// Whether a recording kept at `keptAt` may still be retried at `now`.
    public static func isAvailable(keptAt: TimeInterval, now: TimeInterval) -> Bool {
        let age = now - keptAt
        return age >= 0 && age < keepSeconds
    }

    /// The engine for the automatic retry, or nil when there is none: once per dictation. A
    /// failure or a loop is tried again on the same engine, as Whisper already does inside
    /// itself for loops (so a Whisper loop is not tried a third time); an engine that did not
    /// start hands the recording to another one.
    public static func automatic(
        after trigger: Trigger,
        engine: ComparedEngine,
        attempts: Int,
        parakeetReady: Bool,
        whisperReady: Bool
    ) -> ComparedEngine? {
        guard attempts == 0 else { return nil }
        switch trigger {
        case .didNotStart:
            let other = otherEngine(than: engine, parakeetReady: parakeetReady, whisperReady: whisperReady)
            return other == engine ? nil : other
        case .failed:
            return engine
        case .repeated:
            return engine == .whisper ? nil : engine
        }
    }

    /// *Réessayer*: the recording goes to another engine than the one that just failed, when
    /// one is on disk — never one that would need a download.
    public static func otherEngine(than failed: ComparedEngine, parakeetReady: Bool, whisperReady: Bool) -> ComparedEngine {
        switch failed {
        case .parakeet: .apple
        case .whisper: parakeetReady ? .parakeet : .apple
        case .apple: parakeetReady ? .parakeet : (whisperReady ? .whisper : .apple)
        }
    }
}
