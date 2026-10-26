import Foundation

/// What a dictation or Command Mode shortcut may be (FLU-37), and whether the one in use is
/// actually armed.
///
/// A shortcut is read from the short name it is stored with (« ⌥ Espace », « ⌃ ⌥ »,
/// « ⌘ ⇧ Espace ») through `ShortcutLabel`'s parser, so a preset and the same combination
/// recorded by hand are one shortcut here. Every picker asks `refusal` before it applies a
/// choice: the recorder and the preset menu in Réglages, and the menu bar's picker.
public enum ShortcutRules {
    public enum Modifier: String, CaseIterable, Sendable {
        case control = "⌃"
        case option = "⌥"
        case command = "⌘"
        case shift = "⇧"
    }

    /// A shortcut as the rules see it.
    public struct Combo: Equatable, Sendable {
        public var modifiers: Set<Modifier>
        /// The key held with the modifiers, as `ShortcutLabel` writes it (« Espace », « D »,
        /// « Tab », « F5 »); nil for a modifier-only shortcut (« ⌃ ⌥ »).
        public var key: String?

        public init(modifiers: Set<Modifier>, key: String?) {
            self.modifiers = modifiers
            self.key = key.map(Self.normalized)
        }

        /// From a stored short name.
        public init(shortName: String) {
            var modifiers: Set<Modifier> = []
            var key: String?
            for token in ShortcutLabel.tokens(shortName) {
                // « ⌥ droite » (a migrated name) is still the ⌥ modifier.
                if let first = token.unicodeScalars.first, let modifier = Modifier(rawValue: String(first)) {
                    modifiers.insert(modifier)
                } else if token != "droite", token != "gauche" {
                    key = token
                }
            }
            self.init(modifiers: modifiers, key: key)
        }

        public var isModifierOnly: Bool { key == nil }

        /// One letter is compared in capitals: the recorder writes « D », a hand-edited value
        /// may say « d ».
        private static func normalized(_ key: String) -> String {
            key.count == 1 ? key.uppercased() : key
        }
    }

    /// Which picker is choosing.
    public enum Role: Sendable {
        case dictation
        case commandMode
    }

    /// Why a combination was refused.
    public enum Refusal: Equatable, Sendable {
        /// ⌘C, ⌘V, ⌘Q, ⌘W, ⌘Tab, ⌘ Espace…: holding it to dictate would take it from every app.
        case macOS
        /// ⌥L (language), ⌃⌘V / ⌃⌘C (the last transcript): Fluence already answers to it.
        case fluence
        /// The other shortcut already starts on it (or on part of it).
        case takenByDictation
        case takenByCommandMode
    }

    /// Nil when `candidate` may be used for `role`; `other` is the other picker's shortcut,
    /// nil when Command Mode is off.
    public static func refusal(for candidate: Combo, role: Role, other: Combo?) -> Refusal? {
        if isReservedByMacOS(candidate) { return .macOS }
        if isFluenceShortcut(candidate) { return .fluence }
        if let other, conflict(candidate, other) {
            return role == .dictation ? .takenByCommandMode : .takenByDictation
        }
        return nil
    }

    /// Short, for the recorder's own field: « ⌘ C : réservé à macOS ».
    public static func message(_ refusal: Refusal, label: String) -> String {
        switch refusal {
        case .macOS: "\(label) : réservé à macOS"
        case .fluence: "\(label) : déjà utilisé par Fluence"
        case .takenByDictation: "Déjà pris par la dictée"
        case .takenByCommandMode: "Déjà pris par le Mode Commande"
        }
    }

    /// Two shortcuts that would both start on one press: the same combination, or a
    /// modifier-only one whose modifiers are all held for the other (⌃ ⌥ and ⌃ ⌥ Espace —
    /// holding ⌃ ⌥ starts dictation before Espace is ever pressed).
    public static func conflict(_ a: Combo, _ b: Combo) -> Bool {
        if a == b { return true }
        if a.isModifierOnly, a.modifiers.isSubset(of: b.modifiers) { return true }
        if b.isModifierOnly, b.modifiers.isSubset(of: a.modifiers) { return true }
        return false
    }

    // MARK: Reserved combinations

    /// Keys that, with ⌘ and whatever else is held, belong to the system: the app switcher,
    /// quitting (⌘Q, ⌘⇧Q log out, ⌃⌘Q lock), closing, hiding, minimising, force quit.
    private static let commandKeysAlwaysReserved: Set<String> = ["Tab", "Q", "W", "H", "M", "Échap"]

    static func isReservedByMacOS(_ combo: Combo) -> Bool {
        let mods = combo.modifiers
        guard mods.contains(.command) else { return false }
        guard let key = combo.key else {
            // ⌘ ⇧ held starts every screenshot (⌘⇧3/4/5) and many menu commands.
            return mods == [.command, .shift]
        }
        // ⌘ and one key is an app's menu command: ⌘C, ⌘V, ⌘Z, ⌘S, ⌘ Espace (Spotlight)…
        if mods == [.command] { return true }
        if commandKeysAlwaysReserved.contains(key) { return true }
        // ⌘ ⇧ and a letter or digit: more menu commands (⌘⇧Z, ⌘⇧T) and the screenshots.
        // ⌘ ⇧ Espace stays allowed: it is one of Fluence's presets.
        if mods == [.command, .shift], key.count == 1 { return true }
        return systemCombos.contains(combo)
    }

    /// The rest of macOS's own: emoji viewer, Finder search window, full screen, the Dock.
    private static let systemCombos: [Combo] = [
        Combo(modifiers: [.control, .command], key: "Espace"),
        Combo(modifiers: [.command, .option], key: "Espace"),
        Combo(modifiers: [.control, .command], key: "F"),
        Combo(modifiers: [.command, .option], key: "D"),
    ]

    /// ⌥L switches the language; ⌃⌘V / ⌃⌘C paste and copy the last transcript.
    private static let fluenceCombos: [Combo] = [
        Combo(modifiers: [.option], key: "L"),
        Combo(modifiers: [.control, .command], key: "V"),
        Combo(modifiers: [.control, .command], key: "C"),
    ]

    static func isFluenceShortcut(_ combo: Combo) -> Bool {
        fluenceCombos.contains(combo)
    }
}

/// Whether the dictation shortcut is armed, and if not, why (FLU-37): a combination another
/// app already registered is not an Accessibility problem, and the status chip must not say
/// it is.
public enum HotkeyStatus: Equatable, Sendable {
    case active
    /// The system refused the combination (another app registered it first) and no event
    /// tap can watch it instead.
    case taken
    /// A modifier-only shortcut, or nothing armed at all: only the event tap can watch it,
    /// and the tap needs Accessibility.
    case needsAccessibility

    public static func decide(isModifierOnly: Bool, carbonRegistered: Bool, hasEventTap: Bool) -> HotkeyStatus {
        // The tap watches modifier-only shortcuts, and combinations Carbon could not take.
        if hasEventTap { return .active }
        if isModifierOnly { return .needsAccessibility }
        return carbonRegistered ? .active : .taken
    }
}

extension ShortcutLabel {
    /// The main window's status chip (Clement, FLU-37): the real shortcut, then the engine —
    /// « ⌥ Espace · Parakeet ». No « Raccourci », no language: Parakeet and Whisper are
    /// multilingual, and the same rule holds for every engine.
    public static func status(shortName: String, engine: String, hotkey: HotkeyStatus) -> String {
        switch hotkey {
        case .active: display(shortName) + " · " + engine
        case .taken: display(shortName) + joiner + "indisponible"
        case .needsAccessibility: "Raccourci inactif"
        }
    }

    /// The chip's tooltip.
    public static func statusHelp(shortName: String, hotkey: HotkeyStatus) -> String {
        switch hotkey {
        case .active: "Maintenez \(display(shortName)) pour dicter"
        case .taken: "Une autre app utilise déjà \(display(shortName)) : choisissez un autre raccourci dans Réglages."
        case .needsAccessibility: "Le raccourci n'est pas actif : vérifiez l'autorisation Accessibilité dans les Réglages."
        }
    }
}
