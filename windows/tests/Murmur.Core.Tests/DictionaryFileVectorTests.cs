using System.Text.Json;
using Murmur.Core;
using Murmur.Dictionary;
using Shouldly;
using Xunit;

namespace Murmur.CoreTests;

/// <summary>
/// Runs the <c>fileCases</c> of <c>shared/dictionary-test-vectors.json</c>: how a raw
/// <c>dictionary.txt</c> is read, line endings included.
/// </summary>
/// <remarks>
/// The macOS app runs the same cases through its own parser (FLU-53), so a file saved by
/// either app, or by any editor, reads the same on both.
/// </remarks>
public sealed class DictionaryFileVectorTests
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
    };

    private static readonly FileSuite TheSuite = Load();

    public sealed record FileSuite(int Version, FileCase[] FileCases);

    public sealed record FileCase(string Name, string Text, ExpectedEntry[] ExpectedEntries);

    public sealed record ExpectedEntry(string Kind, string? Hear, string Write, bool? IsEnabled)
    {
        public string Describe() =>
            $"{(Kind.Equals("correction", StringComparison.OrdinalIgnoreCase) ? "correction" : "term")} " +
            $"{Hear ?? string.Empty}->{Write} {((IsEnabled ?? true) ? "on" : "off")}";
    }

    private static FileSuite Load()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "dictionary-test-vectors.json");
        var json = File.ReadAllText(path);
        return JsonSerializer.Deserialize<FileSuite>(json, JsonOptions)
               ?? throw new InvalidOperationException("Test vectors failed to deserialize.");
    }

    private static string Describe(DictionaryEntry entry) =>
        $"{(entry.Kind == EntryKind.Correction ? "correction" : "term")} " +
        $"{entry.Hear}->{entry.Write} {(entry.IsEnabled ? "on" : "off")}";

    /// <summary>Case names, not objects: distinct xUnit IDs, so no case is silently skipped.</summary>
    public static TheoryData<string> CaseNames()
    {
        var data = new TheoryData<string>();
        foreach (var c in TheSuite.FileCases) data.Add(c.Name);
        return data;
    }

    [Theory]
    [MemberData(nameof(CaseNames))]
    public void Shared_file_case_reads_the_contracted_entries(string caseName)
    {
        var testCase = TheSuite.FileCases.Single(c => c.Name == caseName);

        var read = DictionaryFile.Parse(testCase.Text).Select(Describe).ToList();

        read.ShouldBe(testCase.ExpectedEntries.Select(e => e.Describe()).ToList(), $"case '{testCase.Name}'");
    }

    [Fact]
    public void Every_file_case_is_uniquely_named_and_the_section_is_not_empty()
    {
        TheSuite.FileCases.ShouldNotBeEmpty();
        TheSuite.FileCases.Select(c => c.Name).Distinct(StringComparer.Ordinal).Count()
            .ShouldBe(TheSuite.FileCases.Length, "duplicate case names would be silently skipped");
    }
}
