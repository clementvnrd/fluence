using Murmur.Core;
using Murmur.Dictionary;
using Murmur.Testing;
using Shouldly;
using Xunit;

namespace Murmur.CoreTests;

/// <summary>
/// The dictionary's plain-text file format.
/// </summary>
/// <remarks>
/// This format is shared with the macOS build — the same <c>dictionary.txt</c> is meant to
/// work on both — so round-tripping is a compatibility guarantee, not just tidiness.
/// </remarks>
public sealed class DictionaryFileTests : IDisposable
{
    private readonly string _path = Path.Combine(Path.GetTempPath(), $"murmur-dict-{Guid.NewGuid():N}.txt");

    public void Dispose()
    {
        if (File.Exists(_path)) File.Delete(_path);
    }

    [Fact]
    public void Parses_terms_corrections_comments_and_disabled_entries()
    {
        var entries = DictionaryFile.Parse("""
            # Murmur dictionary
            # a plain comment is ignored

            Anthropic
            cloud code -> Claude Code
            # off: whisper flow -> Wispr Flow
            """);

        entries.Count.ShouldBe(3);

        entries[0].Kind.ShouldBe(EntryKind.Term);
        entries[0].Write.ShouldBe("Anthropic");
        entries[0].IsEnabled.ShouldBeTrue();

        entries[1].Kind.ShouldBe(EntryKind.Correction);
        entries[1].Hear.ShouldBe("cloud code");
        entries[1].Write.ShouldBe("Claude Code");

        // A disabled entry survives as a "# off:" comment rather than vanishing — otherwise
        // switching a rule off would quietly delete it on the next save.
        entries[2].Kind.ShouldBe(EntryKind.Correction);
        entries[2].Hear.ShouldBe("whisper flow");
        entries[2].IsEnabled.ShouldBeFalse();
    }

    [Fact]
    public void Round_trips_through_the_file()
    {
        var file = new DictionaryFile(_path);
        file.Add(DictionaryEntry.Term("Anthropic"));
        file.Add(DictionaryEntry.Correction("cloud code", "Claude Code"));
        file.Add(DictionaryEntry.Correction("whisper flow", "Wispr Flow") with { IsEnabled = false });

        var reopened = new DictionaryFile(_path);

        reopened.Entries.Count.ShouldBe(3);
        reopened.Entries[1].Hear.ShouldBe("cloud code");
        reopened.Entries[2].IsEnabled.ShouldBeFalse();
    }

    [Fact]
    public void Malformed_lines_are_skipped_rather_than_throwing()
    {
        // A hand-edited file will contain mistakes. One bad line must not lose the rest.
        var entries = DictionaryFile.Parse("Anthropic\n -> missing left side\nleft side -> \nVercel");

        entries.Count.ShouldBe(2);
        entries.Select(e => e.Write).ShouldBe(["Anthropic", "Vercel"]);
    }

    [Fact]
    public void Search_matches_both_sides_case_insensitively()
    {
        var file = new DictionaryFile(_path);
        file.Add(DictionaryEntry.Correction("cloud code", "Claude Code"));
        file.Add(DictionaryEntry.Term("Vercel"));

        file.Search("CLAUDE").Count.ShouldBe(1);
        file.Search("cloud").Count.ShouldBe(1);
        file.Search("verc").Count.ShouldBe(1);
        file.Search("").Count.ShouldBe(2);
    }

    [Fact]
    public void Update_and_remove_persist()
    {
        var file = new DictionaryFile(_path);
        var entry = DictionaryEntry.Term("Anthropc");
        file.Add(entry);

        file.Update(entry with { Write = "Anthropic" });
        new DictionaryFile(_path).Entries[0].Write.ShouldBe("Anthropic");

        file.Remove(entry.Id);
        new DictionaryFile(_path).Entries.ShouldBeEmpty();
    }
}

/// <summary>Transcript history persistence: sealed at rest, migrated, purged.</summary>
public sealed class TranscriptStoreTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"murmur-hist-{Guid.NewGuid():N}");
    private readonly FakeSecretProtector _protector = new();

    private string HistoryPath => Path.Combine(_directory, "transcripts.jsonl");

    public TranscriptStoreTests() => Directory.CreateDirectory(_directory);

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }

    private TranscriptStore Open() => new(HistoryPath, _protector);

    private static TranscriptRecord Record(string text, DateTimeOffset? at = null) => new()
    {
        At = at ?? DateTimeOffset.UtcNow,
        AudioSeconds = 2,
        ProcessingSeconds = 0.2,
        Text = text,
    };

    [Fact]
    public void Records_round_trip_newest_first()
    {
        using (var store = Open())
        {
            store.Add(Record("first"));
            store.Add(Record("second"));
        }

        using var reopened = Open();

        reopened.Records.Count.ShouldBe(2);
        reopened.Records[0].Text.ShouldBe("second", "newest first is how the list reads");
    }

    [Fact]
    public void Nothing_dictated_is_readable_on_disk()
    {
        using (var store = Open())
        {
            store.Add(Record("my bank PIN is 4711") with
            {
                RawText = "my bank pin is four seven one one",
                Corrections = [new AppliedCorrection("pin", "PIN", 1)],
            });
        }

        var disk = File.ReadAllText(HistoryPath);
        disk.ShouldNotContain("4711");
        disk.ShouldNotContain("PIN");
        disk.ShouldNotContain("four seven");
        File.ReadAllLines(HistoryPath).ShouldAllBe(line => line.StartsWith(HistoryCipher.Prefix, StringComparison.Ordinal));

        // And the key beside it is the wrapped one, not the raw 32 bytes.
        File.ReadAllBytes(TranscriptStore.KeyPathFor(HistoryPath)).Length.ShouldBe(34);
    }

    [Fact]
    public void Raw_text_and_corrections_survive_the_round_trip()
    {
        using (var store = Open())
        {
            store.Add(Record("Claude Code") with
            {
                RawText = "cloud code",
                Corrections = [new AppliedCorrection("cloud code", "Claude Code", 2)],
            });
        }

        using var reopened = Open();
        var record = reopened.Records.ShouldHaveSingleItem();

        record.RawText.ShouldBe("cloud code");
        record.Corrections.ShouldNotBeNull();
        record.Corrections[0].To.ShouldBe("Claude Code");
        record.Corrections[0].Count.ShouldBe(2);
    }

    [Fact]
    public void A_plaintext_history_is_migrated_once_and_the_plaintext_is_gone()
    {
        // Exactly what the pre-sealing build wrote: one JSON object per line.
        File.WriteAllLines(HistoryPath,
        [
            """{"Id":"6f1c2c1e-0000-4000-8000-000000000001","At":"2026-09-01T10:00:00+00:00","AudioSeconds":1,"ProcessingSeconds":0.1,"Text":"old secret one"}""",
            "{ corrupt plaintext",
            """{"Id":"6f1c2c1e-0000-4000-8000-000000000002","At":"2026-09-02T10:00:00+00:00","AudioSeconds":1,"ProcessingSeconds":0.1,"Text":"old secret two"}""",
        ]);

        using (var store = Open())
        {
            store.Records.Select(r => r.Text).ShouldBe(["old secret two", "old secret one"]);
        }

        var disk = File.ReadAllText(HistoryPath);
        disk.ShouldNotContain("old secret");
        disk.ShouldNotContain("corrupt plaintext");

        using var reopened = Open();
        reopened.Records.Count.ShouldBe(2);
    }

    [Fact]
    public void A_corrupt_line_does_not_destroy_the_rest_of_the_history()
    {
        using (var store = Open())
        {
            store.Add(Record("good one"));
            File.AppendAllText(HistoryPath, HistoryCipher.Prefix + "AAAAnot-really-sealed\n");
            store.Add(Record("good two"));
        }

        using var reopened = Open();
        reopened.Records.Count.ShouldBe(2, "one bad line must cost one record, not the file");
    }

    [Fact]
    public void A_key_from_another_account_sets_the_old_history_aside_instead_of_deleting_it()
    {
        using (var store = Open()) store.Add(Record("written by someone else"));

        using var other = new TranscriptStore(HistoryPath, new FakeSecretProtector(identity: 0x11));

        other.Records.ShouldBeEmpty();
        other.IsPersistent.ShouldBeTrue("a fresh history starts under a fresh key");
        other.Problem.ShouldNotBeNull();
        Directory.GetFiles(_directory, "transcripts.unreadable-*.jsonl").ShouldHaveSingleItem();
        Directory.GetFiles(_directory, "transcripts.unreadable-*.key").ShouldHaveSingleItem();
    }

    [Fact]
    public void Without_a_protector_nothing_touches_the_disk()
    {
        using var store = new TranscriptStore(HistoryPath, protector: null);
        store.Add(Record("memory only"));

        store.IsPersistent.ShouldBeFalse();
        store.Records.ShouldHaveSingleItem();
        File.Exists(HistoryPath).ShouldBeFalse("no secure storage must never mean a plaintext fallback");
    }

    [Fact]
    public void Delete_removes_only_the_named_record_and_persists()
    {
        using (var store = Open())
        {
            store.Add(Record("keep me"));
            store.Add(Record("delete me"));

            var doomed = store.Records.Single(r => r.Text == "delete me");
            store.Remove(doomed.Id);
        }

        using var reopened = Open();
        reopened.Records.Select(r => r.Text).ShouldBe(["keep me"]);
    }

    [Fact]
    public void Appending_after_a_delete_still_reads_back_in_order()
    {
        // Deleting rewrites the file; a later append must not scramble the ordering.
        using (var store = Open())
        {
            store.Add(Record("one"));
            store.Add(Record("two"));
            store.Remove(store.Records.Single(r => r.Text == "one").Id);
            store.Add(Record("three"));
        }

        using var reopened = Open();
        reopened.Records.Select(r => r.Text).ShouldBe(["three", "two"]);
    }

    [Fact]
    public void Clear_deletes_the_file()
    {
        using (var store = Open())
        {
            store.Add(Record("gone"));
            store.Clear();
        }

        File.Exists(HistoryPath).ShouldBeFalse();
        using var reopened = Open();
        reopened.Records.ShouldBeEmpty();
    }

    [Fact]
    public void Retention_purges_by_age_and_persists()
    {
        var now = new DateTimeOffset(2026, 10, 7, 12, 0, 0, TimeSpan.Zero);

        using (var store = Open())
        {
            store.Add(Record("two months old", now.AddDays(-60)));
            store.Add(Record("two days old", now.AddDays(-2)));
            store.Add(Record("an hour old", now.AddHours(-1)));

            store.ApplyRetention(HistoryRetention.Forever, now).ShouldBe(0);
            store.ApplyRetention(HistoryRetention.ThirtyDays, now).ShouldBe(1);
            store.ApplyRetention(HistoryRetention.OneDay, now).ShouldBe(1);
        }

        using var reopened = Open();
        reopened.Records.Select(r => r.Text).ShouldBe(["an hour old"]);
    }

    [Fact]
    public void Retention_never_deletes_the_whole_history()
    {
        using (var store = Open())
        {
            store.Add(Record("anything"));
            store.ApplyRetention(HistoryRetention.Never, DateTimeOffset.UtcNow).ShouldBe(1);
            store.Records.ShouldBeEmpty();
        }

        File.Exists(HistoryPath).ShouldBeFalse();
    }

    [Fact]
    public void Retention_defaults_to_thirty_days()
    {
        new SettingsData().HistoryRetention.ShouldBe(HistoryRetention.ThirtyDays);
    }
}

/// <summary>Settings persistence.</summary>
public sealed class AppSettingsTests : IDisposable
{
    private readonly string _path = Path.Combine(Path.GetTempPath(), $"murmur-set-{Guid.NewGuid():N}.json");

    public void Dispose()
    {
        if (File.Exists(_path)) File.Delete(_path);
    }

    [Fact]
    public void Defaults_to_right_ctrl_not_right_alt()
    {
        // Right Alt is AltGr on most European layouts; binding push-to-talk there breaks
        // typing @, €, \ and |. This default is a correctness decision, not a preference.
        new AppSettings(_path).Data.PushToTalkKey.ShouldBe(0xA3);
    }

    [Fact]
    public void Settings_round_trip()
    {
        var settings = new AppSettings(_path);
        settings.Update(settings.Data with { PushToTalkKey = 0x7C, InjectText = false });

        var reopened = new AppSettings(_path);
        reopened.Data.PushToTalkKey.ShouldBe(0x7C);
        reopened.Data.InjectText.ShouldBeFalse();
    }

    [Fact]
    public void Settings_are_saved_atomically_and_round_trip_the_retention()
    {
        var settings = new AppSettings(_path);
        settings.Update(settings.Data with { HistoryRetention = HistoryRetention.OneDay });

        new AppSettings(_path).Data.HistoryRetention.ShouldBe(HistoryRetention.OneDay);
        File.ReadAllText(_path).ShouldContain("\"OneDay\"", Case.Sensitive, "enums are written by name, for hand-editing");
    }

    [Fact]
    public void An_old_keep_history_off_becomes_retention_never()
    {
        File.WriteAllText(_path, """{ "PushToTalkKey": 163, "KeepHistory": false }""");

        var settings = new AppSettings(_path);

        settings.Data.HistoryRetention.ShouldBe(HistoryRetention.Never);
        settings.Data.LegacyKeepHistory.ShouldBeNull();
    }

    [Fact]
    public void Corrupt_settings_fall_back_to_defaults_rather_than_failing_to_launch()
    {
        File.WriteAllText(_path, "{ not json at all");

        new AppSettings(_path).Data.PushToTalkKey.ShouldBe(0xA3);
    }
}

/// <summary>The one-time move from the pre-rename data folder.</summary>
public sealed class AppPathsTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"fluence-paths-{Guid.NewGuid():N}");

    private string Legacy => Path.Combine(_root, "Murmur");
    private string Current => Path.Combine(_root, "Fluence");

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    private static void Write(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
    }

    [Fact]
    public void Nothing_happens_without_a_legacy_folder()
    {
        AppPaths.MigrateLegacyData(Legacy, Current).ShouldBe(DataMigration.NothingToMigrate);
        Directory.Exists(Current).ShouldBeFalse();
    }

    [Fact]
    public void The_legacy_folder_is_moved_not_copied()
    {
        Write(Path.Combine(Legacy, "transcripts.jsonl"), "old history");
        Write(Path.Combine(Legacy, "models", "parakeet-v2", "tokens.txt"), "tokens");

        AppPaths.MigrateLegacyData(Legacy, Current).ShouldBe(DataMigration.Moved);

        File.ReadAllText(Path.Combine(Current, "transcripts.jsonl")).ShouldBe("old history");
        File.Exists(Path.Combine(Current, "models", "parakeet-v2", "tokens.txt")).ShouldBeTrue();
        Directory.Exists(Legacy).ShouldBeFalse("a plaintext copy left behind would defeat sealing the history");
    }

    [Fact]
    public void A_merge_never_overwrites_the_new_folder()
    {
        Write(Path.Combine(Legacy, "settings.json"), "legacy settings");
        Write(Path.Combine(Legacy, "dictionary.txt"), "legacy dictionary");
        Write(Path.Combine(Legacy, "models", "parakeet-v3", "tokens.txt"), "v3");
        Write(Path.Combine(Current, "settings.json"), "new settings");
        Write(Path.Combine(Current, "models", "parakeet-v2", "tokens.txt"), "v2");

        AppPaths.MigrateLegacyData(Legacy, Current).ShouldBe(DataMigration.Merged);

        File.ReadAllText(Path.Combine(Current, "settings.json")).ShouldBe("new settings");
        File.ReadAllText(Path.Combine(Current, "dictionary.txt")).ShouldBe("legacy dictionary");
        File.Exists(Path.Combine(Current, "models", "parakeet-v3", "tokens.txt")).ShouldBeTrue();
        File.Exists(Path.Combine(Current, "models", "parakeet-v2", "tokens.txt")).ShouldBeTrue();

        // The conflicting file stays behind rather than being guessed at.
        File.ReadAllText(Path.Combine(Legacy, "settings.json")).ShouldBe("legacy settings");
    }

    [Fact]
    public void Paths_use_the_product_name()
    {
        AppPaths.DataDirectory.ShouldEndWith("Fluence");
        AppPaths.TranscriptsFile.ShouldStartWith(AppPaths.DataDirectory);
        AppPaths.LogsDirectory.ShouldStartWith(AppPaths.DataDirectory);
    }
}
