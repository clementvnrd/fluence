import FluenceNotesCore
import SwiftUI

/// "Consentement FR / EN": copies the notice to paste into the meeting chat. The keys show
/// "Copié !" briefly through `flash`/`onCopied`, so any owner of a flash can host them.
struct ConsentKeys: View {
    var flash: String?
    let onCopied: (String) -> Void

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            key(.french, title: "Consentement FR")
            key(.english, title: "Consentement EN")
        }
    }

    private func key(_ language: NotesLanguage, title: String) -> some View {
        let token = "consent-" + language.rawValue
        return TransportKey(title: flash == token ? "Copié !" : title, systemImage: "text.bubble") {
            NotetakerConsent.copyNotice(language)
            onCopied(token)
        }
        .help(NotetakerConsent.text(language))
    }
}

/// Library header: the consent keys, under a small label.
struct LibraryHeaderAccessories: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        LabeledFact(label: "Prévenir les participants — copier un avis pour le chat") {
            ConsentKeys(flash: model.flash) { model.showFlash($0) }
        }
    }
}
