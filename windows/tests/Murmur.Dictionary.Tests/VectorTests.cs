using System.Text.Json;
using System.Text.Json.Serialization;
using Murmur.Dictionary;
using Shouldly;
using Xunit;

namespace Murmur.DictionaryTests;

/// <summary>
/// Runs the shared behavioural contract in <c>shared/dictionary-test-vectors.json</c>.
/// </summary>
/// <remarks>
/// The macOS app runs the identical file through its Swift implementation. Since the Windows
/// build cannot be exercised by hand, this is the primary evidence that the correction pass
/// behaves the way the product actually specifies.
/// </remarks>
public sealed class VectorTests
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
    };

    private static readonly Suite TheSuite = Load();

    public sealed record Suite(int Version, Case[] Cases, BiasCase[] BiasCases);

    public sealed record Case(
        string Name,
        Entry[] Entries,
        string Input,
        string Expected,
        ExpectedCorrection[] ExpectedCorrections);

    public sealed record Entry(string Kind, string? Hear, string Write, bool? IsEnabled)
    {
        public DictionaryEntry ToEntry() => new()
        {
            Kind = Kind.Equals("correction", StringComparison.OrdinalIgnoreCase)
                ? EntryKind.Correction
                : EntryKind.Term,
            Write = Write,
            Hear = Hear ?? string.Empty,
            IsEnabled = IsEnabled ?? true,
        };
    }

    public sealed record ExpectedCorrection(string To, int Count);

    /// <summary>
    /// One <c>biasCases</c> entry: a dictionary, the lexicon's spellings (none when missing),
    /// and the bias list the engine must get, in order (FLU-40).
    /// </summary>
    public sealed record BiasCase(string Name, Entry[] Entries, string[]? Seeded, string[] ExpectedBias);

    private static Suite Load()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "dictionary-test-vectors.json");
        var json = File.ReadAllText(path);
        return JsonSerializer.Deserialize<Suite>(json, JsonOptions)
               ?? throw new InvalidOperationException("Test vectors failed to deserialize.");
    }

    /// <summary>
    /// Case <i>names</i>, not case objects.
    /// </summary>
    /// <remarks>
    /// Passing a complex object through <c>MemberData</c> gives every row the same xUnit test
    /// ID, and xUnit then <b>silently skips</b> the duplicates — a suite that reports green
    /// while running one case out of nineteen. Passing a string keeps the IDs distinct.
    /// <see cref="Every_case_is_uniquely_named_and_the_suite_is_not_empty"/> is the guard that
    /// makes that failure mode impossible to reintroduce unnoticed.
    /// </remarks>
    public static TheoryData<string> CaseNames()
    {
        var data = new TheoryData<string>();
        foreach (var c in TheSuite.Cases) data.Add(c.Name);
        return data;
    }

    [Theory]
    [MemberData(nameof(CaseNames))]
    public void Shared_vector_produces_the_contracted_output(string caseName)
    {
        var testCase = TheSuite.Cases.Single(c => c.Name == caseName);
        var corrector = new DictionaryCorrector(testCase.Entries.Select(e => e.ToEntry()));

        var (text, applied) = corrector.Apply(testCase.Input);

        text.ShouldBe(testCase.Expected, $"case '{testCase.Name}'");
        applied.Count.ShouldBe(
            testCase.ExpectedCorrections.Length,
            $"case '{testCase.Name}': got [{string.Join(", ", applied.Select(a => a.To))}]");

        // Order-insensitive: which rule fires first is an implementation detail of the
        // longest-first sort. What fired, and how often, is contractual.
        foreach (var expected in testCase.ExpectedCorrections)
        {
            var match = applied.SingleOrDefault(a => a.To == expected.To);
            match.ShouldNotBeNull($"case '{testCase.Name}': expected a correction to “{expected.To}”");
            match.Count.ShouldBe(expected.Count, $"case '{testCase.Name}': count for “{expected.To}”");
        }
    }

    [Fact]
    public void Every_case_is_uniquely_named_and_the_suite_is_not_empty()
    {
        TheSuite.Cases.ShouldNotBeEmpty();
        TheSuite.Cases.Select(c => c.Name).Distinct(StringComparer.Ordinal).Count()
            .ShouldBe(TheSuite.Cases.Length, "duplicate case names would be silently skipped");
    }

    /// <summary>Bias case names, not objects, for the same reason as <see cref="CaseNames"/>.</summary>
    public static TheoryData<string> BiasCaseNames()
    {
        var data = new TheoryData<string>();
        foreach (var c in TheSuite.BiasCases) data.Add(c.Name);
        return data;
    }

    /// <summary>
    /// The engine is handed the seeded list (<c>DictationEngine</c>), so that is what the shared
    /// cases run; a case without a lexicon seeds nothing.
    /// </summary>
    [Theory]
    [MemberData(nameof(BiasCaseNames))]
    public void Shared_bias_case_gives_the_contracted_spellings_in_order(string caseName)
    {
        var testCase = TheSuite.BiasCases.Single(c => c.Name == caseName);

        var phrases = DictionaryCorrector.BiasPhrases(
            testCase.Entries.Select(e => e.ToEntry()), testCase.Seeded ?? []);

        phrases.ToList().ShouldBe(testCase.ExpectedBias.ToList(), $"case '{testCase.Name}'");
    }

    [Fact]
    public void Every_bias_case_is_uniquely_named_and_the_section_is_not_empty()
    {
        TheSuite.BiasCases.ShouldNotBeEmpty();
        TheSuite.BiasCases.Select(c => c.Name).Distinct(StringComparer.Ordinal).Count()
            .ShouldBe(TheSuite.BiasCases.Length, "duplicate case names would be silently skipped");
    }

    /// <summary>The macOS <c>userSpellingsFirst</c> (FLU-27), run against the Windows code.</summary>
    [Fact]
    public void The_users_own_spellings_lead_the_list_even_behind_a_long_lexicon()
    {
        var lexicon = Enumerable.Range(1, 70).Select(i => DictionaryEntry.Term($"Outil{i}")).ToList();
        var dictionary = lexicon
            .Append(DictionaryEntry.Term("Orsay"))
            .Append(DictionaryEntry.Correction("zoo keeper", "ZooKeeper"))
            .ToList();

        var led = DictionaryCorrector.BiasPhrases(dictionary, lexicon.Select(e => e.Write));

        led.Count.ShouldBe(DictionaryCorrector.BiasLimit);
        led[0].ShouldBe("ZooKeeper");
        led[1].ShouldBe("Orsay");
        led[2].ShouldBe("Outil1");
        led[^1].ShouldBe("Outil38");

        // In file order, the 70 lexicon words fill the list first.
        DictionaryCorrector.BiasPhrases(dictionary).ShouldNotContain("Orsay");
    }

    /// <summary>FLU-40: without a lexicon, a word just added still reaches the engine.</summary>
    [Fact]
    public void Past_the_limit_the_newest_entries_are_offered_first()
    {
        var dictionary = Enumerable.Range(1, 45).Select(i => DictionaryEntry.Term($"Mot{i}")).ToList();

        var phrases = DictionaryCorrector.BiasPhrases(dictionary, []);

        phrases.Count.ShouldBe(DictionaryCorrector.BiasLimit);
        phrases[0].ShouldBe("Mot45");
        phrases[^1].ShouldBe("Mot6");
        phrases.ShouldNotContain("Mot5");
    }

    [Fact]
    public void Bias_list_is_capped_and_deduplicated()
    {
        var entries = Enumerable.Range(0, 100)
            .Select(i => DictionaryEntry.Term($"Word{i}"))
            .Append(DictionaryEntry.Term("Word0"))
            .ToList();

        var phrases = DictionaryCorrector.BiasPhrases(entries);

        phrases.Count.ShouldBe(DictionaryCorrector.BiasLimit);
        phrases.Distinct(StringComparer.OrdinalIgnoreCase).Count().ShouldBe(phrases.Count);
    }

    [Fact]
    public void Disabled_entries_are_excluded_from_biasing()
    {
        DictionaryEntry[] entries =
        [
            DictionaryEntry.Term("Kept"),
            DictionaryEntry.Term("Skipped") with { IsEnabled = false },
        ];

        DictionaryCorrector.BiasPhrases(entries).ShouldBe(["Kept"]);
    }

    [Fact]
    public void An_ordinary_word_used_as_a_trigger_is_flagged() =>
        DictionaryWarning.Check(DictionaryEntry.Correction("cloud", "Claude")).ShouldNotBeEmpty();

    [Fact]
    public void A_distinctive_phrase_is_not_flagged() =>
        DictionaryWarning.Check(DictionaryEntry.Correction("clawed code", "Claude Code")).ShouldBeEmpty();
}
