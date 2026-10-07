import FluenceNotesCore
import SwiftUI

/// "Consentement FR / EN": copies the notice to paste into the meeting chat. The keys show
/// "Copié !" briefly through `flash`/`onCopied`, so any owner of a flash can host them.
struct ConsentKeys: View {
    var flash: String?
    let onCopied: (String) -> Void

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            key(.french, title: "Copier FR")
            key(.english, title: "Copier EN")
        }
    }

    private func key(_ language: NotesLanguage, title: String) -> some View {
        let token = "consent-" + language.rawValue
        return CapButton(title: flash == token ? "Copié !" : title, systemImage: "doc.on.clipboard", height: 26) {
            NotetakerConsent.copyNotice(language)
            onCopied(token)
        }
        .help(NotetakerConsent.text(language))
    }
}
