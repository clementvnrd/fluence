import FluenceCore
import SwiftUI

/// Styles (FLU-12): the tone per kind of app, the style cards of mock-up 08 on a page of
/// their own. The same cards sit in Réglages ▸ Texte.
struct StylesView: View {
    @State private var settings = Settings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                ContentTitle(
                    title: "Styles",
                    subtitle: "Le ton s'adapte à l'app où vous dictez : un message à un ami ne s'écrit pas comme un e-mail."
                )
                .padding(.bottom, DS.Space.snug)

                if settings.cleanupLevel != .high {
                    HStack(spacing: DS.Space.base) {
                        Image(systemName: "info.circle").foregroundStyle(DS.Color.accent)
                        Text("Les styles s'appliquent au niveau de nettoyage Élevé. Niveau actuel : \(settings.cleanupLevel.title).")
                            .font(DS.Font.label)
                            .foregroundStyle(DS.Color.ink)
                        Spacer()
                        CapButton(title: "Passer au niveau Élevé", height: 26) { settings.cleanupLevel = .high }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(DS.Color.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                SectionCard {
                    SettingsRow(systemImage: "textformat", title: "Styles par app", subtitle: "Choisi d'après l'app au premier plan et, dans un navigateur, d'après la page.") {
                        Text(WritingStyle.allCases.map(\.displayName).joined(separator: " · "))
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.silkscreen)
                    }
                    StyleTiles()
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                    RowNote(text: "L'adresse de la page est lue une fois, pour choisir le style, et n'est jamais gardée.")
                }

                SectionCard {
                    SettingsRow(
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        title: "Formatage code & terminaux",
                        subtitle: "Dans les éditeurs et les terminaux : symboles dictés, options de commande, pas de point final."
                    ) {
                        RowToggle(isOn: $settings.appAwareStylesEnabled)
                    }
                }
            }
            .padding(.horizontal, DS.Space.panel)
            .padding(.top, 28)
            .padding(.bottom, DS.Space.panel)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

/// Four cards — Personnel, Travail, E-mail, Autre — each with its apps, its style and an
/// example sentence in that style.
struct StyleTiles: View {
    @State private var settings = Settings.shared

    /// Four across when each card gets this much width, two by two otherwise, so nothing is
    /// cut short in a narrow window (FLU-18).
    static let tileWidth: CGFloat = 150

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(AppCategory.allCases)
            VStack(spacing: 6) {
                row(Array(AppCategory.allCases.prefix(2)))
                row(Array(AppCategory.allCases.dropFirst(2)))
            }
        }
    }

    private func row(_ categories: [AppCategory]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(categories, id: \.self) { category in
                tile(category)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tile(_ category: AppCategory) -> some View {
        let style = settings.style(for: category)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: category.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Color.accent)
                Text(category.tileTitle).font(DS.Font.bodyEmphasis).foregroundStyle(DS.Color.ink)
            }
            Text(category.apps).font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            MenuChip(title: style.displayName, fill: true) {
                ForEach(WritingStyle.allCases, id: \.self) { option in
                    Button {
                        settings.styles[category] = option
                    } label: {
                        if option == style {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            }
            Text(FrenchFormat.quoted(style.frenchExample(for: category)))
                .font(.system(size: 11))
                .italic()
                .foregroundStyle(DS.Color.inkSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, DS.Space.base)
        .frame(minWidth: Self.tileWidth, idealWidth: Self.tileWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Color.well.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline))
    }
}

extension AppCategory {
    /// The card's title (mock-up 08).
    var tileTitle: String {
        switch self {
        case .personal: "Personnel"
        case .work: "Travail"
        case .email: "E-mail"
        case .other: "Autre"
        }
    }

    /// A few of the apps `classify` puts in this category.
    var apps: String {
        switch self {
        case .personal: "Messages, WhatsApp"
        case .work: "Slack, Teams, Google Chat"
        case .email: "Mail, Outlook, Gmail"
        case .other: "Toutes les autres apps"
        }
    }

    var symbol: String {
        switch self {
        case .personal: "person.fill"
        case .work: "briefcase.fill"
        case .email: "envelope.fill"
        case .other: "square.grid.2x2.fill"
        }
    }
}

extension WritingStyle {
    /// How one sentence reads in this style — illustration only, like the cleanup levels'.
    func frenchExample(for category: AppCategory) -> String {
        switch self {
        case .formal:
            category == .email ? "Bonjour Hugo, je reviens vers vous demain." : "Je reviens vers vous cet après-midi."
        case .casual: "Je regarde ça et je reviens vers toi."
        case .veryCasual: "ok pour demain, je t'appelle en sortant"
        }
    }
}
