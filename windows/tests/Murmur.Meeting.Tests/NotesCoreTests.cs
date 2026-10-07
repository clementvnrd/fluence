using Murmur.Meeting;
using Shouldly;
using Xunit;

namespace Murmur.MeetingTests;

/// <summary>Ports of FluenceNotesCoreTests: Markdown, retention, consent, language.</summary>
public sealed class MarkdownTests
{
    private static readonly TimeZoneInfo Paris = TimeZoneInfo.FindSystemTimeZoneById("Europe/Paris");

    // 2026-10-07 12:30 UTC = 14:30 in Paris.
    private static readonly DateTimeOffset Date = DateTimeOffset.FromUnixTimeSeconds(1_791_376_200);

    private static MarkdownMeeting Meeting(FinalNotesDraft? notes, NotesLanguage language = NotesLanguage.English, string userNotes = "") => new()
    {
        Title = "Weekly *sync*",
        StartedAt = Date,
        Duration = 3_900,
        Participants = ["You", "Marie"],
        Language = language,
        Notes = notes,
        UserNotes = userNotes,
        Transcript = [new TranscriptLine(0, "You", "Hello."), new TranscriptLine(75, "Marie", "Let's ship_it\nnow.")],
        TimeZone = Paris,
    };

    [Fact]
    public void Full_document()
    {
        var notes = new FinalNotesDraft
        {
            Recap = "We agreed to ship.\n\nMarie sends the quote.",
            NextSteps = [new ActionDraft("Send the quote", "Marie", "Friday"), new ActionDraft("Book a room")],
            Decisions = ["Ship on Friday"],
        };
        MarkdownRenderer.Render(Meeting(notes, userNotes: "- check *budget*")).ShouldBe("""
            # Weekly \*sync\*

            - **Date:** 2026-10-07 14:30
            - **Duration:** 1 h 05 min
            - **Participants:** You, Marie

            ## Recap

            We agreed to ship.

            Marie sends the quote.

            ## Next steps

            - [ ] Send the quote — **Marie** (due: Friday)
            - [ ] Book a room

            ## Decisions

            - Ship on Friday

            ## Open questions

            _None._

            ## My notes

            - check *budget*

            ## Transcript

            **[00:00] You:** Hello.

            **[01:15] Marie:** Let's ship\_it now.

            """.ReplaceLineEndings("\n"));
    }

    [Fact]
    public void Without_notes_says_so_and_keeps_the_transcript()
    {
        var markdown = MarkdownRenderer.Render(Meeting(null));
        markdown.ShouldContain("_No notes were generated for this meeting._");
        markdown.ShouldNotContain("## Recap");
        markdown.ShouldNotContain("## My notes");
        markdown.ShouldContain("## Transcript");
    }

    [Fact]
    public void French_labels()
    {
        var markdown = MarkdownRenderer.Render(Meeting(
            new FinalNotesDraft { Recap = "Ok.", NextSteps = [new ActionDraft("Envoyer", null, "lundi")] }, NotesLanguage.French));
        markdown.ShouldContain("## Récapitulatif");
        markdown.ShouldContain("- [ ] Envoyer (échéance: lundi)");
        markdown.ShouldContain("- **Durée:** 1 h 05 min");
        markdown.ShouldContain("## Transcription");
    }

    [Fact]
    public void Filenames()
    {
        MarkdownRenderer.Filename("Weekly: sync / Q4?", Date, Paris).ShouldBe("2026-10-07 Weekly sync Q4.md");
        MarkdownRenderer.Filename(" ... ", Date, Paris).ShouldBe("2026-10-07 Meeting.md");
    }

    [Fact]
    public void Durations()
    {
        DurationText.Format(0).ShouldBe("0 min");
        DurationText.Format(20).ShouldBe("< 1 min");
        DurationText.Format(45 * 60).ShouldBe("45 min");
        DurationText.Format((2 * 3600) + (5 * 60)).ShouldBe("2 h 05 min");
    }
}

public sealed class RetentionTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(2_000_000_000);
    private static readonly int[] DaysAgo = [1, 6, 8, 40, 400];

    [Fact]
    public void Choices()
    {
        Retention.Choices.Select(c => c.Days()).ShouldBe([null, 7, 30, 90, 365]);
        Retention.Choice(null).ShouldBe(RetentionChoice.Forever);
        Retention.Choice(0).ShouldBe(RetentionChoice.Forever);
        Retention.Choice(30).ShouldBe(RetentionChoice.Month);
        Retention.Choice(14).ShouldBeNull();
    }

    [Fact]
    public void Cutoff_and_count()
    {
        Retention.Cutoff(null, Now).ShouldBeNull();
        Retention.Cutoff(7, Now).ShouldBe(Now.AddSeconds(-7 * 86_400));
        var dates = DaysAgo.Select(d => Now.AddSeconds(-d * 86_400.0)).ToList();
        Retention.ExpiredCount(dates, null, Now).ShouldBe(0);
        Retention.ExpiredCount(dates, 7, Now).ShouldBe(3);
        Retention.ExpiredCount(dates, 30, Now).ShouldBe(2);
        Retention.ExpiredCount(dates, 365, Now).ShouldBe(1);
    }
}

public sealed class ConsentAndLanguageTests
{
    [Fact]
    public void Consent_texts_match_macOS()
    {
        ConsentNotice.Text(NotesLanguage.French).ShouldStartWith("Je prends des notes de cette réunion avec Fluence");
        ConsentNotice.Text(NotesLanguage.French).ShouldContain("rien n'est envoyé sur Internet");
        ConsentNotice.Text(NotesLanguage.English).ShouldContain("nothing is sent over the Internet");
        ConsentNotice.Bilingual.ShouldBe(ConsentNotice.Text(NotesLanguage.French) + "\n\n" + ConsentNotice.Text(NotesLanguage.English));
    }

    [Fact]
    public void Consent_texts_are_word_for_word_the_Swift_strings()
    {
        // Read from the Swift source so a wording change on one platform fails here.
        var swift = File.ReadAllText(Path.Combine(RepoRoot(), "Sources", "FluenceNotesCore", "ConsentNotice.swift"));
        string Joined(string marker)
        {
            var start = swift.IndexOf(marker, StringComparison.Ordinal);
            var parts = new List<string>();
            var line = swift[start..].Split('\n');
            foreach (var l in line.Skip(1))
            {
                var t = l.Trim();
                if (!t.StartsWith('"') && !t.StartsWith("+ \"", StringComparison.Ordinal)) break;
                var q = t.IndexOf('"', StringComparison.Ordinal);
                parts.Add(t[(q + 1)..t.LastIndexOf('"')]);
            }

            return string.Concat(parts);
        }

        ConsentNotice.Text(NotesLanguage.French).ShouldBe(Joined("case .french:"));
        ConsentNotice.Text(NotesLanguage.English).ShouldBe(Joined("case .english:"));
    }

    [Fact]
    public void Language_tag_wins()
    {
        NotesLanguages.Detect("fr-FR", "the and the and").ShouldBe(NotesLanguage.French);
        NotesLanguages.Detect("en_GB", "le la les des").ShouldBe(NotesLanguage.English);
    }

    [Fact]
    public void Transcript_decides_otherwise()
    {
        const string french = "Alors je pense que c'est bien, on va faire la démo avec les clients et vous nous dites.";
        const string english = "So I think that is fine, we will do the demo with the clients and you tell us.";
        NotesLanguages.Detect(null, french).ShouldBe(NotesLanguage.French);
        NotesLanguages.Detect("de-DE", french).ShouldBe(NotesLanguage.French);
        NotesLanguages.Detect(null, english).ShouldBe(NotesLanguage.English);
        NotesLanguages.Detect(null, "").ShouldBe(NotesLanguage.English);
    }

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "shared", "meeting-test-vectors.json"))) dir = dir.Parent;
        return dir?.FullName ?? throw new InvalidOperationException("repository root not found");
    }
}

public sealed class MeetingExportTests
{
    private static MeetingRecord Meeting() => new()
    {
        Title = "Sync",
        StartedAt = DateTimeOffset.FromUnixTimeSeconds(1_791_376_200),
        EndedAt = DateTimeOffset.FromUnixTimeSeconds(1_791_376_200 + 600),
        Speakers = [Speaker.Me(), new Speaker("S1"), new Speaker("S2")],
        Segments =
        [
            new TranscriptSegment { Source = AudioSource.System, SpeakerId = "S1", Start = 3, End = 4, Text = "Bonjour." },
            new TranscriptSegment { Source = AudioSource.Microphone, SpeakerId = "me", Start = 1, End = 2, Text = "Hi." },
            new TranscriptSegment { Source = AudioSource.System, SpeakerId = "S1", Start = 5, End = 6, Text = "Encore." },
        ],
        Notes = new MeetingNotes { Recap = "r", NextSteps = [new ActionItem("Send it", "Speaker 1")] },
    };

    [Fact]
    public void Renaming_a_speaker_renames_every_line_and_owner_and_marks_it_as_the_users()
    {
        var renamed = Meeting().RenameSpeaker("S1", "  Marie ");
        renamed.SpeakerById("S1").ShouldBe(new Speaker("S1", "Marie", NameSource.User));
        renamed.Lines().Select(l => l.Speaker).ShouldBe(["You", "Marie", "Marie"]);
        renamed.Notes!.NextSteps.Single().Owner.ShouldBe("Marie");
        renamed.ParticipantNames().ShouldBe(["You", "Marie"]);

        var cleared = renamed.RenameSpeaker("S1", " ");
        cleared.SpeakerById("S1").ShouldBe(new Speaker("S1"));
    }

    [Fact]
    public void Markdown_export_uses_display_names_in_time_order()
    {
        var markdown = Meeting().RenameSpeaker("S1", "Marie").Markdown(TimeZoneInfo.Utc);
        markdown.ShouldContain("**[00:01] You:** Hi.\n\n**[00:03] Marie:** Bonjour.");
        markdown.ShouldContain("- **Participants:** You, Marie");
        markdown.ShouldContain("- [ ] Send it — **Marie**");
        Meeting().MarkdownFilename(TimeZoneInfo.Utc).ShouldBe("2026-10-07 Sync.md");
    }
}
