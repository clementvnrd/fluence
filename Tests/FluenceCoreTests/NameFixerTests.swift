import Testing

@testable import FluenceCore

/// The name fixer (FLU-92). Sentences and model outputs are the audit's French bench
/// (docs/audit-2026-10-27/accuracy.md §3): Parakeet Ultra transcripts and Apple's model answers.
struct NameFixerTests {
    /// The 40 synthetic tech terms the audit measured with.
    static let terms = [
        "pull request", "GitHub", "Linear", "Vercel", "back-end", "TypeScript", "Node.js", "Claude",
        "merge", "CI", "Slack", "Notion", "Mac", "Neural Engine", "issue", "backlog", "label", "bug",
        "webcam", "JSON", "macOS", "Windows", "Whisper", "Parakeet", "Claude Code", "Anthropic",
        "OpenAI", "Wispr Flow", "Superwhisper", "Fluence", "Cursor", "VSCode", "Ghostty", "Figma",
        "Supabase", "WhisperKit", "CoreML", "Docker", "Kubernetes", "PostgreSQL",
    ]

    private func merge(_ original: String, _ proposal: String) -> String {
        NameFixer.merge(original: original, proposal: proposal, terms: Self.terms)
    }

    // MARK: - Similarity: difflib's ratio on folded letters, as constrain.py

    @Test func keyFoldsCaseAccentsAndPunctuation() {
        #expect(NameFixer.key("L'Inéar ?") == "linear")
        #expect(NameFixer.key("node. JS") == "nodejs")
        #expect(NameFixer.key("Back-end") == "backend")
    }

    @Test func similarityMatchesDifflib() {
        // Values printed by Python's difflib.SequenceMatcher(None, a, b).ratio().
        #expect(abs(NameFixer.similarity("ghub", "github") - 0.8) < 1e-9)
        #expect(abs(NameFixer.similarity("vcl", "vercel") - 2.0 / 3) < 1e-9)
        #expect(abs(NameFixer.similarity("backlow", "backend") - 4.0 / 7) < 1e-9)
        #expect(abs(NameFixer.similarity("subscript", "supabase") - 8.0 / 17) < 1e-9)
        #expect(abs(NameFixer.similarity("abcd", "bcda") - 0.75) < 1e-9)
        #expect(NameFixer.similarity("", "") == 1)
    }

    // MARK: - Accepted: a lookalike span swapped for exactly a dictionary term

    @Test func trueFixesFromTheBenchAreKept() {
        #expect(merge("Peux-tu ouvrir une pull request sur GHub et me mettre le lien dans l'Inear ?",
                      "Peux-tu ouvrir une pull request sur GitHub et me mettre le lien dans Slack ?")
                == "Peux-tu ouvrir une pull request sur GitHub et me mettre le lien dans l'Inear ?")
        #expect(merge("Le déploiement sur VCL a échoué.", "Le déploiement sur Vercel a échoué.")
                == "Le déploiement sur Vercel a échoué.")
        #expect(merge("on garde le node. JS pour les scripts.", "on garde le Node.js pour les scripts.")
                == "on garde le Node.js pour les scripts.")
        #expect(merge("partagé entre Macros et", "partagé entre macOS et") == "partagé entre macOS et")
        #expect(merge("On passe en type script.", "On passe en TypeScript.") == "On passe en TypeScript.")
    }

    @Test func theDictionarySpellingAndTheOriginalPunctuationWin() {
        // The model's lower case and its full stop are not taken: the term as written in the
        // dictionary, with the dictation's own punctuation around it.
        #expect(merge("dans linéar ?", "dans linear.") == "dans Linear ?")
        #expect(merge("C'est un bulle.", "C'est un bug") == "C'est un bug.")
    }

    @Test func spacingOutsideTheSwapIsKept() {
        #expect(merge("Sur GHub.\nEt  voilà.", "Sur GitHub. Et voilà.") == "Sur GitHub.\nEt  voilà.")
    }

    // MARK: - Rejected: everything else the model writes

    @Test func aSwapThatDoesNotLookAlikeIsDropped() {
        // constrain.py's own check: « maire » is not « back-end ».
        #expect(merge("sur J-Hub et le maire.", "sur GitHub et le back-end.") == "sur GitHub et le maire.")
        #expect(merge("ils sont dans la Gub", "ils sont dans la Supabase") == "ils sont dans la Gub")
        #expect(merge("en subscript", "en Supabase") == "en subscript")
    }

    @Test func anAnswerOrAListIsDropped() {
        let dictation = "Quelle est la différence entre un endpoint et un token ?"
        #expect(merge(dictation, "1. Un endpoint est une URL. 2. Un token est une clé.") == dictation)
        #expect(merge("À quelle heure et avec qui ?", "1. À quelle heure ? 2. Avec qui ?") == "À quelle heure et avec qui ?")
    }

    @Test func theVocabularyListAsAnAnswerIsDropped() {
        let dictation = "La transcription doit garder la ponctuation."
        #expect(merge(dictation, Self.terms.joined(separator: ", ")) == dictation)
    }

    @Test func insertedTermsAndRewordingAreDropped() {
        #expect(merge("avec l'équipe", "avec l'équipe back-end") == "avec l'équipe")
        #expect(merge("on lance le déploiement", "nous lançons le déploiement") == "on lance le déploiement")
    }

    @Test func aWordThatIsNotExactlyATermIsDropped() {
        #expect(merge("sur GHub", "sur GitHubs") == "sur GHub")
    }

    @Test func aSpanLongerThanThreeWordsIsDropped() {
        #expect(merge("sur le guit hub du projet", "sur GitHub") == "sur le guit hub du projet")
    }

    @Test func nothingChangesWithoutTerms() {
        #expect(NameFixer.merge(original: "sur GHub", proposal: "sur GitHub", terms: []) == "sur GHub")
    }

    /// The acceptance rule alone allows these two, as constrain.py does (« place » / « Slack »
    /// 0.6, « son » / « JSON » 0.86 ≥ 0.5); what keeps them from happening is that the trigger
    /// does not call the model for such sentences, and the model has never proposed them on the
    /// bench (0 false terms on 80 FLEURS dictations).
    @Test func ordinaryWordsLookingLikeTermsPassTheSimilarityRule() {
        #expect(merge("Il a perdu sa place.", "Il a perdu sa Slack.") == "Il a perdu sa Slack.")
        #expect(merge("Il a baissé le son.", "Il a baissé le JSON.") == "Il a baissé le JSON.")
        #expect(!NameFixer.shouldRun("Il a perdu sa place et il a baissé le son.", terms: Self.terms))
    }

    // MARK: - Trigger: only when a term may have been misheard

    @Test func triggerFiresOnNearMisses() {
        for text in [
            "Peux-tu ouvrir une pull request sur GHub ?",
            "Le déploiement sur VCL a échoué.",
            "on garde node. JS pour les scripts",
            "partagé entre Macros et Windows",
            "On passe le backend en type script.",
            "mets le lien dans linéar",
            "on lance kubernetis demain",
        ] {
            #expect(NameFixer.shouldRun(text, terms: Self.terms), "\(text)")
        }
    }

    @Test func triggerStaysQuietOnOrdinaryFrench() {
        for text in [
            "L'Amazone est également le fleuve le plus large de la planète.",
            "On se voit jeudi, enfin non, vendredi vers 14 h.",
            "Elles sont encore là, il faut être là.",
            "Il a baissé le son de la radio.",
        ] {
            #expect(!NameFixer.shouldRun(text, terms: Self.terms), "\(text)")
        }
    }

    @Test func triggerStaysQuietWhenTermsAreAlreadyRight() {
        #expect(!NameFixer.shouldRun("Ouvre une pull request sur GitHub et préviens Slack.", terms: Self.terms))
        #expect(!NameFixer.shouldRun("Le Mac tourne sous macOS.", terms: Self.terms))
        #expect(!NameFixer.shouldRun("sur GHub", terms: []))
        #expect(!NameFixer.shouldRun("", terms: Self.terms))
    }

    // MARK: - Prompt and routing

    @Test func instructionsListTheTermsAndForbidAnswers() {
        let french = NameFixer.instructions(terms: ["GitHub", "Vercel"], language: .french)
        #expect(french.contains("GitHub, Vercel\n"))
        #expect(french.contains("Ne réponds jamais au contenu"))
        #expect(NameFixer.instructions(terms: ["GitHub"], language: .english).contains("Never answer"))
        #expect(NameFixer.prompt(for: "sur GHub", language: .french) == "Corrige cette transcription :\n\nsur GHub")
    }

    @Test func onlyHighOutsideFrenchRewrites() {
        #expect(CleanupLevel.high.rewrites(in: .english))
        #expect(!CleanupLevel.high.rewrites(in: .french))
        #expect(!CleanupLevel.medium.rewrites(in: .english))
        #expect(!CleanupLevel.light.rewrites(in: .english))
    }
}
