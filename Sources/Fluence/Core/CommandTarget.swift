import AppKit
import ApplicationServices
import FluenceCore
import Foundation

/// The text Command Mode rewrites (FLU-5): the selection in the focused field, or — when
/// nothing is selected — the field's whole contents. Read and written through Accessibility.
///
/// Read once, when the spoken instruction ends, and checked again before writing: the
/// rewrite takes seconds, and if the user has clicked elsewhere or changed the selection
/// meanwhile, replacing "the selection" would overwrite something they never asked to have
/// rewritten. In that case nothing is written.
///
/// There is no ⌘C fallback for apps whose selection AX cannot read: copying would put the
/// user's text on the pasteboard under the target app's name, in plain view of every
/// clipboard manager's history. Such apps get a clear message instead.
@MainActor
struct CommandTarget {
    enum Scope {
        case selection
        case wholeField
    }

    enum Failure: Error {
        case noFocus
        case secureField
        case unreadable
        case empty
        case tooLong

        /// Short enough for the HUD's two-line readout.
        var message: String {
            switch self {
            case .noFocus: "Cliquez d'abord dans le texte à modifier."
            case .secureField: "Le Mode Commande ignore les mots de passe."
            case .unreadable: "Cette app cache son texte à Fluence."
            case .empty: "Sélectionnez d'abord du texte."
            case .tooLong: "Trop de texte. Sélectionnez un passage plus court."
            }
        }
    }

    let element: AXUIElement
    let text: String
    let scope: Scope

    /// Same budget as `TextInjector`: a hung app must not freeze Fluence with it.
    private static let axTimeout: Float = 0.5

    static func read() -> Result<CommandTarget, Failure> {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axTimeout)
        guard let element = focusedElement() else { return .failure(.noFocus) }

        if string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) {
            return .failure(.secureField)
        }

        let selected = string(element, kAXSelectedTextAttribute)
        let value = string(element, kAXValueAttribute)

        let text: String
        let scope: Scope
        if let selected, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = selected
            scope = .selection
        } else if let value {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.empty)
            }
            text = value
            scope = .wholeField
        } else {
            return .failure(selected == nil ? .unreadable : .empty)
        }

        guard text.count <= CommandRewrite.maximumInputCharacters else { return .failure(.tooLong) }
        return .success(CommandTarget(element: element, text: text, scope: scope))
    }

    /// Puts `rewritten` where the text was read from.
    ///
    /// - Returns: `false` when the focus or the text moved since `read()`; nothing was
    ///   written then.
    func replace(with rewritten: String) -> Bool {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.axTimeout)
        guard let current = Self.focusedElement(), CFEqual(current, element) else { return false }

        switch scope {
        case .selection:
            guard Self.string(element, kAXSelectedTextAttribute) == text else { return false }
        case .wholeField:
            guard Self.string(element, kAXValueAttribute) == text else { return false }
            // Select everything, so the insert below replaces the field rather than adding
            // to it — on the AX path and on the paste fallback alike.
            var range = CFRange(location: 0, length: text.utf16.count)
            guard let value = AXValueCreate(.cfRange, &range),
                  AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success,
                  Self.string(element, kAXSelectedTextAttribute) == text
            else { return false }
        }

        // The same verified insert dictation uses: AX first, the safe pasteboard otherwise.
        // With the text selected, inserting replaces it.
        TextInjector.insert(rewritten)
        return true
    }

    // MARK: - AX

    private static func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let focused else { return nil }
        return unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
