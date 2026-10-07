import FluenceNotesCore
import SwiftUI

/// "Consent FR / EN": copies the notice to paste into the meeting chat. The keys show
/// "Copied" briefly through `flash`/`onCopied`, so any owner of a flash can host them.
struct ConsentKeys: View {
    var flash: String?
    let onCopied: (String) -> Void

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            key(.french, title: "Consent FR")
            key(.english, title: "Consent EN")
        }
    }

    private func key(_ language: NotesLanguage, title: String) -> some View {
        let token = "consent-" + language.rawValue
        return TransportKey(title: flash == token ? "Copied" : title, systemImage: "text.bubble") {
            NotetakerConsent.copyNotice(language)
            onCopied(token)
        }
        .help(NotetakerConsent.text(language))
    }
}

/// Library header: the consent keys, under a silkscreen label.
struct LibraryHeaderAccessories: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        LabeledFact(label: "Tell the others — copy a notice for the chat") {
            ConsentKeys(flash: model.flash) { model.showFlash($0) }
        }
    }
}
