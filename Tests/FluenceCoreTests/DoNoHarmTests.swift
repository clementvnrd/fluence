import Testing

@testable import FluenceCore

/// Everyday sentences that cleanup at level Light must type exactly as they were said
/// (FLU-27). Light is the default level; a rule that changes one of these deletes or rewrites
/// words the user really said, which costs more than any filler it removes.
///
/// The chain is the one `DictationPipeline` runs for Light, outside developer tools.
/// Sentences are written already capitalised and punctuated, so a correct chain returns them
/// unchanged. Every rule added to Light extends this list first.
struct DoNoHarmTests {
    static func light(_ text: String, _ language: DictationLanguage) -> String {
        SpeechRepairs.after(LightCleanup.apply(text, language: language), language: language, developer: false)
    }

    /// French typography puts a no-break space before « ? ! : ; »; it is not a change of words.
    static func words(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    static let french = [
        // « en fait », « je voulais dire », « ou plutôt » used as ordinary French (F1).
        "Je pensais que c'était facile, en fait c'est compliqué.",
        "Coucou je voulais dire que je serai en retard.",
        "C'est simple, en fait il suffit de redémarrer.",
        "Il est parti tôt, en fait il était malade.",
        "Ce que je voulais dire, c'est que le budget est serré.",
        "Je préfère le thé, ou plutôt le café le matin.",
        // A short word before a longer one that starts the same way (F2).
        "On va valider le devis demain.",
        "Celui qui quitte la réunion ferme la porte.",
        "Je jette un œil ce soir.",
        "Il illustre bien le problème.",
        "Il faut que quelque chose change.",
        "Mon monde tourne autour de ce projet.",
        "Son sondage a eu beaucoup de réponses.",
        "Je ne suis pas passé au bureau aujourd'hui.",
        "Tu tues le suspense avec ce titre.",
        // Repeats that are meant.
        "Nous nous sommes vus hier.",
        "Vous vous trompez de salle.",
        "C'est très très bien.",
        // Ordinary work sentences.
        "Le client attend une réponse avant vendredi.",
        "On se retrouve chez Paul après le travail.",
        "Merci pour ton retour sur la maquette.",
        "J'ai relu le contrat et tout me semble correct.",
        "La branche principale compile sans erreur.",
        "Le projet avance bien malgré les délais.",
        "Elle a validé la proposition ce matin.",
        "Il y a un souci avec la facture de mars.",
        "Je vais voir avec l'équipe et je reviens vers toi.",
        "Ça marche, on fait comme ça.",
        "Pas de problème, je m'en occupe.",
        "On a fini la démo, il reste les tests.",
        "Je suis en route, j'arrive dans un quart d'heure.",
        "Peux-tu m'envoyer le fichier avant midi ?",
        // Punctuation words used as nouns (FLU-30, F4): only a command at a clause end.
        "Il y a un point d'interrogation sur le budget.",
        "Gros point d'interrogation sur le budget.",
        "J'ai deux points à voir avec toi.",
        "Il reste deux points importants.",
        "Excellent point.",
        "C'est le point final du projet.",
        "Mets des points de suspension à la fin.",
        "Il manque un point-virgule à la ligne 4.",
        // An ordinal inside a set phrase is not a list (F10).
        "En premier lieu, je voudrais remercier l'équipe.",
        "En deuxième lieu, il faut revoir le budget.",
        // Emphatic repeats (F12).
        "Oui, oui, oui, oui, oui, d'accord.",
        // Cancel words inside a sentence are speech, not « scratch that » (FLU-87).
        "Si le fichier est trop vieux supprime ça et on recommence demain.",
        "Pour la réunion de jeudi annule ça s'il te plaît.",
        "Le client a dit efface ça de la présentation.",
        "Si le vol est retardé, annule tout le reste du voyage.",
        "Quand la réunion est finie, efface ça du tableau.",
        "Bonjour efface tout, salut.",
        // Emphatic doubles said every day (FLU-90).
        "Si si, c'est vrai.",
        "Oh là là, quelle journée.",
        "Vite vite, on va rater le train.",
        "Allez allez, on y va.",
        "Bon bon, on verra demain.",
        "Bien bien, merci pour tout.",
        "Encore encore, c'est trop bien.",
        // A real short word before a longer one is not a stutter (FLU-90).
        "Je relis le mail mailing avant l'envoi.",
        "Le dossier data dataset est vide.",
    ]

    /// French typed into a terminal or an editor: Clement's prompts to Claude Code (FLU-30, F6).
    /// Code formatting must leave prose alone, full stop included.
    static let frenchInDeveloperTools = [
        "Le résultat est différent de ce qu'on attendait.",
        "Appuie sur la flèche droite pour avancer.",
        "Je le colle dans le terminal et je relance.",
        "Il y a un point d'interrogation sur le budget.",
    ]

    static let english = [
        "It was hard, actually it was impossible.",
        "Please make that change today.",
        "So I meant to say thanks for the help.",
        "We need to be better at testing.",
        "Let's go over the plan before the meeting.",
        "I think we can ship it on Friday.",
        "The team will review it tomorrow morning.",
        "She will see the doctor on Monday.",
        "Thanks for the quick reply.",
        "This is the best option we have.",
        "We met at the station and walked home.",
    ]

    @Test(arguments: french)
    func frenchStaysAsSaid(_ sentence: String) {
        let typed = Self.words(Self.light(sentence, .french))
        #expect(typed == sentence, "typed: \(typed)")
    }

    @Test(arguments: english)
    func englishStaysAsSaid(_ sentence: String) {
        let typed = Self.light(sentence, .english)
        #expect(typed == sentence, "typed: \(typed)")
    }

    /// The repairs Light exists for still happen.
    @Test(arguments: [
        ("rendez-vous mardi, en fait mercredi", DictationLanguage.french, "Rendez-vous mercredi."),
        ("envoie-le à Paul, en fait Marie", .french, "Envoie-le à Marie."),
        ("on se voit le 12, en fait 14", .french, "On se voit le 14."),
        // French typography writes the amount as « 400 € » (FLU-30, F13).
        ("le budget est de 300 non attends 400 euros", .french, "Le budget est de 400 €."),
        ("un pro problème", .french, "Un problème."),
        // A real word cut off with a hyphen is still a stutter (FLU-90).
        ("le mail- mailing", .french, "Le mailing."),
        ("c'est c'est bien", .french, "C'est bien."),
        // A French cancel is a command only as the whole dictation or after a pause at its
        // end (FLU-87): the dictation is dropped.
        ("annule ça", .french, ""),
        ("le budget est validé, annule ça.", .french, ""),
        ("Envoie-le à Paul. Efface tout.", .french, ""),
        ("send it to Paul scratch that send it to Marie", .english, "Send it to Marie."),
        ("meet on Tuesday, actually Wednesday", .english, "Meet on Wednesday."),
        ("let's meet at three no wait four", .english, "Let's meet at four."),
        ("send it in May, actually June", .english, "Send it in June."),
    ])
    func intendedRepairsStillHappen(_ said: String, _ language: DictationLanguage, _ typed: String) {
        #expect(Self.words(Self.light(said, language)) == typed)
    }

    // MARK: - FLU-30

    static func developer(_ text: String, _ language: DictationLanguage) -> String {
        SpeechRepairs.after(LightCleanup.apply(text, language: language, developer: true), language: language, developer: true)
    }

    /// No French typography in a terminal or a code editor (FLU-90): a no-break space there
    /// breaks commands and diffs.
    @Test func noFrenchTypographyInDeveloperTools() {
        let typed = Self.developer("La réunion est à 15h30 : on valide ? Ça coûte 2500 euros !", .french)
        #expect(typed == "La réunion est à 15h30: on valide? Ça coûte 2500 euros!")
        #expect(!typed.contains("\u{00A0}"))
    }

    /// The model's fallback is Light itself (F9): the repairs included, not the rules alone.
    @Test func lightIsRepairsThenRules() {
        let said = "un pro problème, en fait c'est c'est réglé"
        #expect(LightCleanup.apply(said, language: .french)
            == RuleCleanup.apply(SpeechRepairs.before(said, language: .french), language: .french))
        #expect(LightCleanup.apply("un pro problème", language: .french) == "Un problème.")
    }

    @Test(arguments: frenchInDeveloperTools)
    func frenchProseInDeveloperToolsStaysAsSaid(_ sentence: String) {
        let typed = Self.words(Self.developer(sentence, .french))
        #expect(typed == sentence, "typed: \(typed)")
    }

    /// Commands still become marks: at a clause end, and a spoken « point » where the engine
    /// already wrote a full stop replaces it (F5: « …devis point. », 4 clips out of 4).
    @Test(arguments: [
        ("Je t'envoie le devis point.", "Je t'envoie le devis."),
        ("Je t'envoie le devis. Point.", "Je t'envoie le devis."),
        ("je t'envoie le devis point", "Je t'envoie le devis."),
        ("on se voit demain point à plus tard", "On se voit demain point à plus tard."),
        ("tu viens demain point d'interrogation", "Tu viens demain ?"),
        ("tu viens demain point d'interrogation. Je pars", "Tu viens demain ? Je pars."),
        ("trois choses deux points le pain virgule le lait", "Trois choses : le pain, le lait."),
        ("voici la liste deux points", "Voici la liste :"),
        ("c'est fini point final", "C'est fini."),
        // As the engine hands them over, without the stop: nouns, not commands (F4).
        ("excellent point", "Excellent point."),
        ("j'ai deux points à voir", "J'ai deux points à voir."),
        ("un point d'interrogation sur le budget", "Un point d'interrogation sur le budget."),
    ])
    func punctuationCommandsStillWork(_ said: String, _ typed: String) {
        #expect(Self.words(Self.light(said, .french)) == typed)
    }

    /// Code formatting still happens on what looks like a command, or after « code : ».
    @Test(arguments: [
        ("git commit double tiret amend", "Git commit --amend"),
        ("if x différent de null", "If x != null"),
        ("code deux points x différent de null", "x != null"),
        ("code : la flèche droite", "la ->"),
    ])
    func codeFormattingStillWorksOnCommands(_ said: String, _ typed: String) {
        #expect(Self.words(Self.developer(said, .french)) == typed)
    }

    /// French number typography (F13), with no-break spaces.
    @Test(arguments: [
        ("La réunion est à 15h30.", "La réunion est à 15\u{00A0}h\u{00A0}30."),
        ("On se voit à 9h.", "On se voit à 9\u{00A0}h."),
        ("Le devis est de 2500 euros.", "Le devis est de 2\u{00A0}500\u{00A0}€."),
        ("Le devis est de 2500€.", "Le devis est de 2\u{00A0}500\u{00A0}€."),
        ("Ça coûte 1 euro.", "Ça coûte 1\u{00A0}€."),
        ("Ça coûte 3,50 euros.", "Ça coûte 3,50\u{00A0}€."),
        ("Il faut 120000 euros.", "Il faut 120\u{00A0}000\u{00A0}€."),
        ("La marge est de 4,2%.", "La marge est de 4,2\u{00A0}%."),
        // Years, postcodes and ratios are not amounts.
        ("C'était en 2026, à 15h30.", "C'était en 2026, à 15\u{00A0}h\u{00A0}30."),
        ("J'habite au 75011 Paris.", "J'habite au 75011 Paris."),
        ("Le support répond 24h/24.", "Le support répond 24h/24."),
        ("Il est 14:30.", "Il est 14:30."),
    ])
    func frenchNumberTypography(_ said: String, _ typed: String) {
        let once = Self.light(said, .french)
        #expect(once == typed)
        #expect(FrenchTypography.apply(to: once) == once, "idempotent")
    }

    /// English is left as it is: the typography is French.
    @Test func englishNumbersAreLeftAlone() {
        #expect(Self.light("It costs 2500 euros at 4.2%.", .english) == "It costs 2500 euros at 4.2%.")
    }

    /// Lists still happen when the ordinal opens an item (F10).
    @Test func spokenListsStillWork() {
        let text = SpeechRepairs.after("Les courses. En premier, du pain. En deuxième, du lait.", language: .french, developer: false)
        #expect(text == "Les courses\n1. Du pain\n2. Du lait.")
    }

    /// The loop guard (F12): emphatic repeats followed by other words are speech; a real loop
    /// is still caught.
    @Test func emphaticRepeatsPassTheLoopGuard() {
        #expect(!TranscriptHealth.isDegenerate("Oui, oui, oui, oui, oui, d'accord."))
        #expect(!TranscriptHealth.isDegenerate("Non non non non non, pas comme ça."))
        #expect(!TranscriptHealth.isDegenerate("Allez, allez, allez, allez, allez, on y va."))
        #expect(TranscriptHealth.isDegenerate("Oui, oui, oui, oui, oui, oui."))
        #expect(TranscriptHealth.isDegenerate(
            Array(repeating: "Node.js", count: 30).joined(separator: ", ") + ". Et la suite."))
    }

    // MARK: - FLU-84

    /// Parakeet hears « à jour » as « à genre » after a form of *mettre* (Clement's history,
    /// 2026-10-26). « mettre à genre » is never French, so the repair is safe.
    @Test(arguments: [
        ("j'ai mis à genre mon app et j'ai merge", "J'ai mis à jour mon app et j'ai merge."),
        ("il faut mettre à genre le dictionnaire", "Il faut mettre à jour le dictionnaire."),
        ("la mise à genre est publiée", "La mise à jour est publiée."),
        ("les mises à genre automatiques", "Les mises à jour automatiques."),
        ("je mets à genre la doc", "Je mets à jour la doc."),
        ("on met à genre les modèles", "On met à jour les modèles."),
        ("vous mettez à genre vos apps", "Vous mettez à jour vos apps."),
        ("il mettra à genre demain", "Il mettra à jour demain."),
        ("tu as remis à genre la liste", "Tu as remis à jour la liste."),
        ("Mise à genre de Fluence", "Mise à jour de Fluence."),
        ("c'est mis a genre", "C'est mis à jour."),
    ])
    func misAGenreBecomesMisAJour(_ said: String, _ typed: String) {
        #expect(LightCleanup.apply(said, language: .french) == typed)
    }

    /// « genre » keeps every meaning it has outside « mettre à genre ».
    @Test(arguments: [
        ("c'est un genre de mise à jour", "C'est un genre de mise à jour."),
        ("ce n'est pas mon genre", "Ce n'est pas mon genre."),
        ("un roman mis à l'honneur, quel genre de livre", "Un roman mis à l'honneur, quel genre de livre."),
        ("le genre musical de la mise en scène", "Le genre musical de la mise en scène."),
        ("elle a mis, genre, trois heures", "Elle a mis, trois heures."),
    ])
    func genreOutsideMettreStays(_ said: String, _ typed: String) {
        #expect(LightCleanup.apply(said, language: .french) == typed)
    }
}
