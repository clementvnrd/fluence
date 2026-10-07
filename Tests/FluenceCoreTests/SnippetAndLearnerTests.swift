import Foundation
import Testing

@testable import FluenceCore

struct AppCategoryTests {
    @Test func nativeApps() {
        #expect(AppCategory.classify(bundleID: "com.apple.MobileSMS", url: nil) == .personal)
        #expect(AppCategory.classify(bundleID: "net.whatsapp.WhatsApp", url: nil) == .personal)
        #expect(AppCategory.classify(bundleID: "com.tinyspeck.slackmacgap", url: nil) == .work)
        #expect(AppCategory.classify(bundleID: "com.microsoft.teams2", url: nil) == .work)
        #expect(AppCategory.classify(bundleID: "com.apple.mail", url: nil) == .email)
        #expect(AppCategory.classify(bundleID: "com.microsoft.Outlook", url: nil) == .email)
        #expect(AppCategory.classify(bundleID: "com.apple.TextEdit", url: nil) == .other)
        #expect(AppCategory.classify(bundleID: nil, url: nil) == .other)
    }

    @Test func browsersGoByTheirFrontTab() {
        let chrome = "com.google.Chrome"
        #expect(AppCategory.classify(bundleID: chrome, url: "https://mail.google.com/mail/u/0/#inbox") == .email)
        #expect(AppCategory.classify(bundleID: chrome, url: "https://outlook.live.com/mail/") == .email)
        #expect(AppCategory.classify(bundleID: "com.apple.Safari", url: "https://acme.slack.com/client/T1/C2") == .work)
        #expect(AppCategory.classify(bundleID: "com.apple.Safari", url: "https://teams.microsoft.com/v2/") == .work)
        #expect(AppCategory.classify(bundleID: "company.thebrowser.Browser", url: "web.whatsapp.com") == .personal)
        #expect(AppCategory.classify(bundleID: "org.mozilla.firefox", url: "https://www.messenger.com/t/1") == .personal)
        #expect(AppCategory.classify(bundleID: chrome, url: "https://news.ycombinator.com") == .other)
        #expect(AppCategory.classify(bundleID: chrome, url: nil) == .other)
    }

    @Test func aLookalikeHostIsNotTheRealThing() {
        #expect(AppCategory.classify(host: "notslack.com") == .other)
        #expect(AppCategory.classify(host: "slack.com.evil.example") == .other)
    }

    @Test func aUrlMeansNothingOutsideABrowser() {
        #expect(AppCategory.classify(bundleID: "com.apple.TextEdit", url: "https://mail.google.com") == .other)
    }

    @Test func defaultStyles() {
        #expect(AppCategory.personal.defaultStyle == .casual)
        #expect(AppCategory.work.defaultStyle == .formal)
        #expect(AppCategory.email.defaultStyle == .formal)
        #expect(AppCategory.other.defaultStyle == .formal)
    }
}

struct SnippetTests {
    private let address = Snippet(trigger: "my address", expansion: "12 rue de la Paix, 75002 Paris")
    private let work = Snippet(trigger: "my work address", expansion: "1 Infinite Loop")
    private let calendly = Snippet(trigger: "mon lien de réunion", expansion: "https://cal.com/clement")

    @Test func wholeUtteranceIgnoresCasePunctuationAndAccents() {
        #expect(SnippetMatcher.wholeUtterance("My address.", snippets: [address]) == address)
        #expect(SnippetMatcher.wholeUtterance("Mon lien de reunion !", snippets: [calendly]) == calendly)
        #expect(SnippetMatcher.wholeUtterance("my address is new", snippets: [address]) == nil)
    }

    @Test func phraseInsideADictation() {
        let text = "Please send it to my address, thanks"
        let found = SnippetMatcher.matches(in: text, snippets: [address])
        #expect(found.count == 1)
        #expect(found.first.map { String(text[$0.range]) } == "my address")
    }

    @Test func longestTriggerWins() {
        let text = "ship it to my work address today"
        let found = SnippetMatcher.matches(in: text, snippets: [address, work])
        #expect(found.map(\.snippet) == [work])
    }

    @Test func wholeWordsOnly() {
        #expect(SnippetMatcher.matches(in: "my addresses are old", snippets: [address]).isEmpty)
        #expect(SnippetMatcher.matches(in: "summy address", snippets: [address]).isEmpty)
    }

    @Test func aSentenceBreakSplitsATrigger() {
        #expect(SnippetMatcher.matches(in: "That's my. Address book", snippets: [address]).isEmpty)
        #expect(SnippetMatcher.matches(in: "That's my, address", snippets: [address]).count == 1)
    }

    @Test func protectAndRestoreKeepTheExpansionVerbatim() {
        let (shielded, expansions) = SnippetMatcher.protect("um send it to my address please", snippets: [address])
        #expect(shielded == "um send it to ⟦1⟧ please")
        let cleaned = RuleCleanup.apply(shielded, language: .english)
        #expect(cleaned == "Send it to ⟦1⟧ please.")
        #expect(SnippetMatcher.restore(cleaned, expansions: expansions) == "Send it to 12 rue de la Paix, 75002 Paris please.")
    }

    @Test func aSnippetOpeningTheSentenceKeepsTheNextWordLowercase() {
        let (shielded, expansions) = SnippetMatcher.protect("my address is the new one", snippets: [address])
        let cleaned = RuleCleanup.apply(shielded, language: .english)
        #expect(SnippetMatcher.restore(cleaned, expansions: expansions) == "12 rue de la Paix, 75002 Paris is the new one.")
    }

    @Test func aMangledPlaceholderFailsTheRestore() {
        #expect(SnippetMatcher.restore("Send it to ⟦1⟧ and ⟦1⟧", expansions: ["x"]) == nil)
        #expect(SnippetMatcher.restore("Send it to 1", expansions: ["x"]) == nil)
        #expect(SnippetMatcher.restore("Send ⟦2⟧ to ⟦1⟧", expansions: ["a"]) == nil)
        #expect(SnippetMatcher.restore("Send ⟦2⟧ to ⟦1⟧", expansions: ["a", "b"]) == "Send b to a")
        // An expansion containing the marker character is substituted, not re-checked.
        #expect(SnippetMatcher.restore("A ⟦1⟧", expansions: ["⟦x⟧"]) == "A ⟦x⟧")
    }

    @Test func validation() {
        #expect(address.problem(among: [address]) == nil)
        #expect(Snippet(trigger: "  ", expansion: "x").problem(among: []) != nil)
        #expect(Snippet(trigger: String(repeating: "a", count: 61), expansion: "x").problem(among: []) != nil)
        #expect(Snippet(trigger: "ok", expansion: String(repeating: "x", count: 4_001)).problem(among: []) != nil)
        #expect(Snippet(trigger: "My Address", expansion: "y").problem(among: [address]) != nil)
    }
}

struct EditLearnerTests {
    @Test func aCorrectedNameIsProposed() {
        let proposals = EditLearner.proposals(inserted: "Ask clod about the release.", edited: "Ask Claude about the release.")
        #expect(proposals == [EditLearner.Proposal(heard: "clod", written: "Claude")])
        #expect(proposals.first?.isCorrection == true)
    }

    @Test func aCommonWordBecomesATermNotARewrite() {
        let proposals = EditLearner.proposals(inserted: "We use cloud daily.", edited: "We use Claude daily.")
        #expect(proposals.map(\.written) == ["Claude"])
        // A rule "cloud -> Claude" would rewrite every cloud.
        #expect(proposals.first?.isCorrection == false)
    }

    @Test func aPhraseIsProposedWhole() {
        let proposals = EditLearner.proposals(inserted: "Open cloud code now.", edited: "Open Claude Code now.")
        #expect(proposals == [EditLearner.Proposal(heard: "cloud code", written: "Claude Code")])
        #expect(proposals.first?.isCorrection == true)
    }

    @Test func gluedAndSplitWords() {
        #expect(EditLearner.proposals(inserted: "It runs on cloud flare.", edited: "It runs on Cloudflare.")
            == [EditLearner.Proposal(heard: "cloud flare", written: "Cloudflare")])
    }

    @Test func ordinaryEditsTeachNothing() {
        // Grammar, a lowercase word, a capital at a sentence start, a rephrasing.
        #expect(EditLearner.proposals(inserted: "Put it over their.", edited: "Put it over there.").isEmpty)
        #expect(EditLearner.proposals(inserted: "hello there.", edited: "Hello there.").isEmpty)
        #expect(EditLearner.proposals(inserted: "the meeting moved.", edited: "The meeting moved.").isEmpty)
        #expect(EditLearner.proposals(inserted: "See you monday.", edited: "See you Monday.").isEmpty)
        #expect(EditLearner.proposals(inserted: "Mail me.", edited: "Mail me at bob@example.com.").isEmpty)
    }

    @Test func aCaseFixMidSentenceIsProposedAsATerm() {
        let proposals = EditLearner.proposals(inserted: "I asked anthropic yesterday.", edited: "I asked Anthropic yesterday.")
        #expect(proposals.map(\.written) == ["Anthropic"])
        #expect(proposals.first?.isCorrection == false)
        #expect(EditLearner.proposals(inserted: "My new iphone.", edited: "My new iPhone.").map(\.written) == ["iPhone"])
    }

    @Test func frenchToo() {
        let proposals = EditLearner.proposals(inserted: "J'ai parlé à jean luc ce matin.", edited: "J'ai parlé à Jean-Luc ce matin.")
        #expect(proposals == [EditLearner.Proposal(heard: "jean luc", written: "Jean-Luc")])
    }

    @Test func tooLongIsNotAName() {
        let long = String(repeating: "Abcdefghij", count: 5)
        #expect(EditLearner.proposals(inserted: "Use xyz.", edited: "Use \(long).").isEmpty)
    }

    @Test func theEditedSpanIsFoundInTheField() {
        let before = "Dear team, Ask clod about it. Thanks"
        let inserted = (before as NSString).range(of: "Ask clod about it.")
        let range = inserted.location..<(inserted.location + inserted.length)
        let after = "Dear team, Ask Claude about it. Thanks"
        #expect(EditLearner.editedSpan(before: before, after: after, inserted: range) == "Ask Claude about it.")
        // An edit elsewhere in the field isn't a correction of the dictation.
        #expect(EditLearner.editedSpan(before: before, after: "Hi team, Ask clod about it. Thanks", inserted: range) == nil)
        #expect(EditLearner.editedSpan(before: before, after: before, inserted: range) == nil)
    }
}
