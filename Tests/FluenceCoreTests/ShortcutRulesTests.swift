import Foundation
import Testing

@testable import FluenceCore

private let nbsp = "\u{00A0}"

/// FLU-37: one label for the configured shortcut everywhere, conflicts refused in every
/// picker, and a shortcut another app holds said as such.
struct ShortcutRulesTests {
    /// The short names of `PushToTalkKey.allCases` (the app target, not importable here).
    private static let presets = ["⌥ Espace", "⌃ Espace", "⌃ ⌥", "⌘ ⌥", "⌥ D", "⌃ D", "⌘ ⇧ Espace", "⌃ ⌥ Espace"]

    private func combo(_ shortName: String) -> ShortcutRules.Combo { ShortcutRules.Combo(shortName: shortName) }

    // MARK: Label

    @Test func theChipShowsTheRealShortcutThenTheEngine() {
        #expect(ShortcutLabel.status(shortName: "⌥ Espace", engine: "Parakeet", hotkey: .active) == "⌥\(nbsp)Espace · Parakeet")
        #expect(ShortcutLabel.status(shortName: "⌃ ⌥", engine: "Whisper", hotkey: .active) == "⌃\(nbsp)⌥ · Whisper")
        #expect(ShortcutLabel.status(shortName: "⌘ ⇧ Espace", engine: "Apple", hotkey: .active) == "⌘\(nbsp)⇧\(nbsp)Espace · Apple")
    }

    @Test func theChipNeverSaysRaccourciOrALanguageWhenActive() {
        for preset in Self.presets {
            for engine in ["Apple", "Whisper", "Parakeet"] {
                let text = ShortcutLabel.status(shortName: preset, engine: engine, hotkey: .active)
                #expect(!text.contains("Raccourci"))
                #expect(!text.contains("Français") && !text.contains("English") && !text.contains("Auto"))
                #expect(text.hasPrefix(ShortcutLabel.display(preset)))
            }
        }
    }

    /// The sidebar is 244 pt; the chip gets about 196 pt of text at 11 pt. 30 characters is
    /// what fits without the chip's own shrinking (measured on the mock-up board).
    @Test func everyPresetChipFitsTheSidebar() {
        for preset in Self.presets {
            for engine in ["Apple", "Whisper", "Parakeet"] {
                #expect(ShortcutLabel.status(shortName: preset, engine: engine, hotkey: .active).count <= 30)
            }
        }
    }

    @Test func aTakenShortcutIsSaidAsSuchNotBlamedOnAccessibility() {
        let text = ShortcutLabel.status(shortName: "⌥ Espace", engine: "Parakeet", hotkey: .taken)
        #expect(text == "⌥\(nbsp)Espace\(nbsp)indisponible")
        let help = ShortcutLabel.statusHelp(shortName: "⌥ Espace", hotkey: .taken)
        #expect(help.contains("Une autre app"))
        #expect(!help.contains("Accessibilité"))
        #expect(ShortcutLabel.statusHelp(shortName: "⌃ ⌥", hotkey: .needsAccessibility).contains("Accessibilité"))
        #expect(ShortcutLabel.statusHelp(shortName: "⌥ Espace", hotkey: .active) == "Maintenez ⌥\(nbsp)Espace pour dicter")
    }

    // MARK: Hotkey status

    @Test func aCombinationOnlyCarbonCouldTakeIsTakenWithoutTheTap() {
        #expect(HotkeyStatus.decide(isModifierOnly: false, carbonRegistered: true, hasEventTap: false) == .active)
        #expect(HotkeyStatus.decide(isModifierOnly: false, carbonRegistered: false, hasEventTap: false) == .taken)
        // The tap watches what Carbon could not register.
        #expect(HotkeyStatus.decide(isModifierOnly: false, carbonRegistered: false, hasEventTap: true) == .active)
        #expect(HotkeyStatus.decide(isModifierOnly: true, carbonRegistered: false, hasEventTap: false) == .needsAccessibility)
        #expect(HotkeyStatus.decide(isModifierOnly: true, carbonRegistered: false, hasEventTap: true) == .active)
    }

    // MARK: Parsing

    @Test func aPresetAndTheSameCombinationRecordedByHandAreOneShortcut() {
        #expect(combo("⌥ Espace") == ShortcutRules.Combo(modifiers: [.option], key: "Espace"))
        #expect(combo("Option+Space") == combo("⌥ Espace"))
        #expect(combo("⌃ ⌥") == ShortcutRules.Combo(modifiers: [.control, .option], key: nil))
        #expect(combo("⌃ ⌥").isModifierOnly)
        #expect(combo("⌥ d") == combo("⌥ D"))
        #expect(combo("rightOption") == ShortcutRules.Combo(modifiers: [.option], key: nil))
    }

    // MARK: Refusals

    @Test func theRecorderRefusesTheShortcutsEveryAppUses() {
        for name in ["⌘ C", "⌘ V", "⌘ Q", "⌘ W", "⌘ Tab", "⌘ Espace", "⌘ Z", "⌘ ⇧ Tab", "⌘ ⇧ Z", "⌘ ⇧ 4",
                     "⌃ ⌘ Q", "⌘ ⌥ Échap", "⌃ ⌘ Espace", "⌃ ⌘ F", "⌘ ⌥ D", "⌘ ⇧ Q", "⌘ ⌥ W", "⌘ ⇧"] {
            #expect(ShortcutRules.refusal(for: combo(name), role: .dictation, other: nil) == .macOS, "\(name)")
        }
    }

    @Test func theRecorderRefusesFluencesOwnChords() {
        for name in ["⌥ L", "⌃ ⌘ V", "⌃ ⌘ C"] {
            #expect(ShortcutRules.refusal(for: combo(name), role: .dictation, other: nil) == .fluence, "\(name)")
            #expect(ShortcutRules.refusal(for: combo(name), role: .commandMode, other: nil) == .fluence, "\(name)")
        }
    }

    @Test func everyPresetIsAllowedOnItsOwn() {
        for preset in Self.presets {
            #expect(ShortcutRules.refusal(for: combo(preset), role: .dictation, other: nil) == nil, "\(preset)")
            #expect(ShortcutRules.refusal(for: combo(preset), role: .commandMode, other: nil) == nil, "\(preset)")
        }
    }

    @Test func ordinaryCombinationsStayAllowed() {
        for name in ["⌃ ⌥ D", "⌥ ⇧ Espace", "⌃ F5", "⌘ ⌥", "⌃ ⇧", "⌥ F1"] {
            #expect(ShortcutRules.refusal(for: combo(name), role: .dictation, other: nil) == nil, "\(name)")
        }
    }

    @Test func theCommandKeyCanNeverBeTheDictationKey() {
        // In both pickers, and whichever was chosen first.
        #expect(ShortcutRules.refusal(for: combo("⌥ Espace"), role: .commandMode, other: combo("⌥ Espace")) == .takenByDictation)
        #expect(ShortcutRules.refusal(for: combo("⌥ Espace"), role: .dictation, other: combo("⌥ Espace")) == .takenByCommandMode)
        // A preset and the same combination recorded by hand.
        #expect(ShortcutRules.refusal(for: combo("Option + Space"), role: .commandMode, other: combo("⌥ Espace")) == .takenByDictation)
        // A modifier-only shortcut starts before the other's key is pressed.
        #expect(ShortcutRules.refusal(for: combo("⌃ ⌥ Espace"), role: .commandMode, other: combo("⌃ ⌥")) == .takenByDictation)
        #expect(ShortcutRules.refusal(for: combo("⌃ ⌥"), role: .dictation, other: combo("⌃ ⌥ D")) == .takenByCommandMode)
        // Different combinations are fine.
        #expect(ShortcutRules.refusal(for: combo("⌘ ⌥"), role: .commandMode, other: combo("⌃ ⌥")) == nil)
        #expect(ShortcutRules.refusal(for: combo("⌃ Espace"), role: .commandMode, other: combo("⌥ Espace")) == nil)
        #expect(ShortcutRules.refusal(for: combo("⌥ D"), role: .commandMode, other: combo("⌃ ⌥")) == nil)
    }

    @Test func refusalsAreShortFrench() {
        let label = ShortcutLabel.display("⌘ C")
        #expect(ShortcutRules.message(.macOS, label: label) == "⌘\(nbsp)C : réservé à macOS")
        #expect(ShortcutRules.message(.fluence, label: ShortcutLabel.display("⌥ L")) == "⌥\(nbsp)L : déjà utilisé par Fluence")
        #expect(ShortcutRules.message(.takenByDictation, label: label) == "Déjà pris par la dictée")
        #expect(ShortcutRules.message(.takenByCommandMode, label: label) == "Déjà pris par le Mode Commande")
    }
}
