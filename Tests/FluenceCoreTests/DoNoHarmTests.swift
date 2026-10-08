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
        let repaired = SpeechRepairs.before(text, language: language)
        let cleaned = RuleCleanup.apply(repaired, language: language)
        return SpeechRepairs.after(cleaned, language: language, developer: false)
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
        ("le budget est de 300 non attends 400 euros", .french, "Le budget est de 400 euros."),
        ("un pro problème", .french, "Un problème."),
        ("c'est c'est bien", .french, "C'est bien."),
        ("bonjour efface tout, salut", .french, "Salut."),
        ("meet on Tuesday, actually Wednesday", .english, "Meet on Wednesday."),
        ("let's meet at three no wait four", .english, "Let's meet at four."),
        ("send it in May, actually June", .english, "Send it in June."),
    ])
    func intendedRepairsStillHappen(_ said: String, _ language: DictationLanguage, _ typed: String) {
        #expect(Self.words(Self.light(said, language)) == typed)
    }
}
