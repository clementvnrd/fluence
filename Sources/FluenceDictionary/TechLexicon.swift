import Foundation

/// Base native de vocabulaire technique, anglicismes et mapping phonétique
/// pour les utilisateurs francophones travaillant dans la tech, le dev et le produit.
public enum TechLexicon {

    /// Termes et corrections pré-configurés pour le code, Git, le Cloud et les startups.
    public static let defaultEntries: [DictionaryEntry] = [
        // MARK: - Git & Version Control
        .correction(hear: "mèrdge", write: "merge"),
        .correction(hear: "merdge", write: "merge"),
        .correction(hear: "pouche", write: "push"),
        .correction(hear: "poule request", write: "pull request"),
        .correction(hear: "poules request", write: "pull request"),
        .correction(hear: "pool request", write: "pull request"),
        .correction(hear: "la pière", write: "la PR"),
        .correction(hear: "une pière", write: "une PR"),
        .correction(hear: "cette pière", write: "cette PR"),
        .correction(hear: "la pr", write: "la PR"),
        .correction(hear: "commite", write: "commit"),
        .correction(hear: "committer", write: "commiter"),
        .correction(hear: "re-base", write: "rebase"),
        .correction(hear: "re-factor", write: "refactor"),
        .correction(hear: "refactore", write: "refactor"),
        .correction(hear: "tcherry pick", write: "cherry-pick"),
        .correction(hear: "branche menne", write: "branch main"),
        // Not « branche master » → « branch master »: « la branche master » is French (FLU-30).
        .correction(hear: "guite", write: "git"),
        .correction(hear: "guithub", write: "GitHub"),
        .correction(hear: "guite lab", write: "GitLab"),

        // MARK: - Dev, Code & Frameworks
        .correction(hear: "dibeug", write: "debug"),
        .correction(hear: "débeug", write: "debug"),
        .correction(hear: "débuguer", write: "debugger"),
        .correction(hear: "diploie", write: "deploy"),
        .correction(hear: "déploie en prod", write: "déploie en prod"),
        .correction(hear: "la prode", write: "la prod"),
        .correction(hear: "en prode", write: "en prod"),
        .correction(hear: "la pré-prod", write: "la préprod"),
        .correction(hear: "stèdjing", write: "staging"),
        .correction(hear: "stédjing", write: "staging"),
        .correction(hear: "pipe-line", write: "pipeline"),
        .correction(hear: "pipe line", write: "pipeline"),
        .correction(hear: "céhi cédé", write: "CI/CD"),
        .correction(hear: "ci cd", write: "CI/CD"),
        .correction(hear: "bac-end", write: "backend"),
        .correction(hear: "baque inde", write: "backend"),
        .correction(hear: "fronte-end", write: "frontend"),
        .correction(hear: "fronte inde", write: "frontend"),
        .correction(hear: "full stack", write: "fullstack"),
        .correction(hear: "foule stack", write: "fullstack"),
        .correction(hear: "type script", write: "TypeScript"),
        .correction(hear: "tape script", write: "TypeScript"),
        .correction(hear: "java script", write: "JavaScript"),
        .correction(hear: "next js", write: "Next.js"),
        .correction(hear: "node js", write: "Node.js"),
        .correction(hear: "vue js", write: "Vue.js"),
        .correction(hear: "nuxt js", write: "Nuxt.js"),
        .correction(hear: "taille wind", write: "Tailwind"),
        .correction(hear: "swift ui", write: "SwiftUI"),
        .correction(hear: "dokère", write: "Docker"),
        .correction(hear: "koubernétis", write: "Kubernetes"),
        .correction(hear: "k huit s", write: "K8s"),
        .correction(hear: "k8s", write: "K8s"),
        .correction(hear: "poste gresse", write: "PostgreSQL"),
        .correction(hear: "mongo db", write: "MongoDB"),
        .correction(hear: "reste api", write: "REST API"),
        .correction(hear: "reste à pays", write: "REST API"),
        .correction(hear: "graph ql", write: "GraphQL"),
        .correction(hear: "graphe ql", write: "GraphQL"),
        .correction(hear: "wèbe houke", write: "webhook"),
        .correction(hear: "web hook", write: "webhook"),
        .correction(hear: "paie lode", write: "payload"),
        .correction(hear: "taukène", write: "token"),
        .correction(hear: "end point", write: "endpoint"),
        .correction(hear: "inde pointe", write: "endpoint"),
        .correction(hear: "staque trace", write: "stacktrace"),
        .correction(hear: "taille maoute", write: "timeout"),
        .correction(hear: "ritraille", write: "retry"),

        // MARK: - Product, Agile & Startup
        .correction(hear: "fide baque", write: "feedback"),
        .correction(hear: "fiture", write: "feature"),
        .correction(hear: "fiturs", write: "features"),
        .correction(hear: "issiou", write: "issue"),
        .correction(hear: "riouiou", write: "review"),
        .correction(hear: "riwiou", write: "review"),
        .correction(hear: "code riouiou", write: "code review"),
        .correction(hear: "stande-up", write: "standup"),
        .correction(hear: "stand up", write: "standup"),
        // Not « le colle » or « en colle »: « je le colle », « j'en colle » are French (FLU-30).
        .correction(hear: "un colle", write: "un call"),
        .correction(hear: "raude mape", write: "roadmap"),
        .correction(hear: "dède laigne", write: "deadline"),
        .correction(hear: "brenne storming", write: "brainstorming"),
        .correction(hear: "aune boarding", write: "onboarding"),
        .correction(hear: "saigne of", write: "sign-off"),
        .correction(hear: "couique ouine", write: "quick win"),
        .correction(hear: "ouane to ouane", write: "1-to-1"),
        .correction(hear: "1 to 1", write: "1-to-1"),
        .correction(hear: "one to one", write: "1-to-1"),
        .correction(hear: "nau go", write: "no-go"),
        .correction(hear: "aime v pays", write: "MVP"),
        .correction(hear: "capiaille", write: "KPI"),
        .correction(hear: "k pays", write: "KPI"),
        .correction(hear: "assap", write: "ASAP"),
        .correction(hear: "a s a p", write: "ASAP"),

        // MARK: - Franglais (FLU-122)
        // English work words said the French way, as Parakeet writes them. Only spellings that
        // are no French word: « crawl », « fixe », « col », « remise » stay as heard.
        .correction(hear: "crône", write: "cron"),
        .correction(hear: "crone", write: "cron"),
        .correction(hear: "cline", write: "clean"),
        .correction(hear: "cliné", write: "cleané"),
        .correction(hear: "cliner", write: "cleaner"),
        .correction(hear: "cléané", write: "cleané"),
        .correction(hear: "cléaner", write: "cleaner"),
        .correction(hear: "liné", write: "leané"),
        .correction(hear: "léané", write: "leané"),
        .correction(hear: "féature", write: "feature"),
        .correction(hear: "féatures", write: "features"),
        .correction(hear: "réfacto", write: "refacto"),
        .correction(hear: "réfecto", write: "refacto"),
        .correction(hear: "backlow", write: "backlog"),
        .correction(hear: "roadma", write: "roadmap"),
        .correction(hear: "pûché", write: "pushé"),
        .correction(hear: "chippé", write: "shippé"),

        // MARK: - Tech Tools & AI
        .term("Claude Code"),
        .term("Anthropic"),
        .term("OpenAI"),
        .term("Wispr Flow"),
        .term("Superwhisper"),
        .term("Fluence"),
        .term("Cursor"),
        .term("VSCode"),
        .term("Ghostty"),
        .term("Linear"),
        .term("Notion"),
        .term("Figma"),
        .term("Supabase"),
        .term("Vercel"),
        .term("WhisperKit"),
        .term("CoreML")
    ]


    /// Entries an earlier lexicon seeded into dictionaries and that were dropped because their
    /// trigger is ordinary French (FLU-30): « je le colle dans Slack » became « je le call »,
    /// « la branche master » « la branch master ». A dictionary seeded before keeps them until
    /// its owner removes them: nothing rewrites the user's file on its own.
    public static let retired: [DictionaryEntry] = [
        .correction(hear: "le colle", write: "le call"),
        .correction(hear: "en colle", write: "en call"),
        .correction(hear: "branche master", write: "branch master"),
    ]

    /// The retired entries still in `entries` exactly as they were seeded — same trigger,
    /// same spelling, still on. One the user edited or switched off is theirs now, and stays.
    public static func retiredEntries(in entries: [DictionaryEntry]) -> [DictionaryEntry] {
        entries.filter { entry in
            entry.isEnabled && retired.contains {
                $0.kind == entry.kind && $0.hear == entry.hear && $0.write == entry.write
            }
        }
    }
}
