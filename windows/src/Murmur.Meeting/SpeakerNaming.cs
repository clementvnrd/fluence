using System.Globalization;
using System.Text;

namespace Murmur.Meeting;

/// <summary>
/// Minimum-cost assignment (Kuhn–Munkres, O(n³)) on a rectangular cost matrix. Port of
/// <c>Hungarian.swift</c>.
/// </summary>
/// <remarks>
/// Used to match remote voices to names: each voice gets at most one name, each name at most
/// one voice, and the total cost is minimal — unlike greedy "best match first".
/// </remarks>
public static class Hungarian
{
    /// <summary>Solves the assignment.</summary>
    /// <param name="cost">Rows × columns, every row the same length. Finite values only.</param>
    /// <returns>For each row, the assigned column, or null when the row was left out.</returns>
    public static IReadOnlyList<int?> Assign(IReadOnlyList<IReadOnlyList<double>> cost)
    {
        ArgumentNullException.ThrowIfNull(cost);

        var rows = cost.Count;
        if (rows == 0) return [];
        var columns = cost[0].Count;
        if (columns == 0) return new int?[rows];

        var n = Math.Max(rows, columns);
        var pad = cost.SelectMany(r => r).Select(Math.Abs).DefaultIfEmpty(0).Max() + 1;

        // 1-indexed square matrix; padded cells cost the same, so they never bias a choice.
        var a = new double[n + 1, n + 1];
        for (var i = 0; i <= n; i++)
        {
            for (var j = 0; j <= n; j++) a[i, j] = pad;
        }

        for (var i = 0; i < rows; i++)
        {
            for (var j = 0; j < columns; j++) a[i + 1, j + 1] = cost[i][j];
        }

        var u = new double[n + 1];
        var v = new double[n + 1];
        var p = new int[n + 1];   // p[j] = row matched to column j
        var way = new int[n + 1];

        for (var i = 1; i <= n; i++)
        {
            p[0] = i;
            var j0 = 0;
            var minv = Enumerable.Repeat(double.PositiveInfinity, n + 1).ToArray();
            var used = new bool[n + 1];
            do
            {
                used[j0] = true;
                var i0 = p[j0];
                var delta = double.PositiveInfinity;
                var j1 = 0;
                for (var j = 1; j <= n; j++)
                {
                    if (used[j]) continue;
                    var current = a[i0, j] - u[i0] - v[j];
                    if (current < minv[j])
                    {
                        minv[j] = current;
                        way[j] = j0;
                    }

                    if (minv[j] < delta)
                    {
                        delta = minv[j];
                        j1 = j;
                    }
                }

                for (var j = 0; j <= n; j++)
                {
                    if (used[j])
                    {
                        u[p[j]] += delta;
                        v[j] -= delta;
                    }
                    else
                    {
                        minv[j] -= delta;
                    }
                }

                j0 = j1;
            }
            while (p[j0] != 0);

            do
            {
                var j1 = way[j0];
                p[j0] = p[j1];
                j0 = j1;
            }
            while (j0 != 0);
        }

        var result = new int?[rows];
        for (var j = 1; j <= n; j++)
        {
            if (p[j] >= 1 && p[j] <= rows && j <= columns) result[p[j] - 1] = j - 1;
        }

        return result;
    }
}

/// <summary>The evidence <see cref="SpeakerNaming.Name"/> weighs.</summary>
public sealed record NamingCandidates
{
    /// <summary>Remote display names read from the meeting window, the user excluded.</summary>
    public IReadOnlyList<string> WindowParticipants { get; init; } = [];

    /// <summary>Calendar attendees, the user excluded.</summary>
    public IReadOnlyList<string> Attendees { get; init; } = [];

    /// <summary>
    /// Speaker id → candidate name → cosine similarity of the voice to the enrolled print.
    /// Already restricted by the caller to the names it allows.
    /// </summary>
    public IReadOnlyDictionary<string, IReadOnlyDictionary<string, double>> VoicePrintSimilarity { get; init; } =
        new Dictionary<string, IReadOnlyDictionary<string, double>>();
}

/// <summary>
/// Puts names on the remote voices <c>S1…Sn</c> after diarization, most trusted source first.
/// Port of <c>SpeakerNaming.swift</c>; contract: <c>shared/meeting-test-vectors.json</c>, <c>naming</c>.
/// </summary>
/// <remarks>
/// <list type="number">
/// <item><b>Meeting window</b> — only when it cannot be wrong about who is who: exactly one
/// remote voice and exactly one remote participant.</item>
/// <item><b>Voice prints</b> (opt-in) — Hungarian assignment on cosine similarity, restricted by
/// the caller to the allowed names. Pairs below <see cref="MinimumSimilarity"/> stay unnamed.</item>
/// <item><b>Elimination</b> — exactly one voice unnamed and exactly one candidate unused: first the
/// window participants (when the window lists as many remote people as there are voices), then
/// the calendar attendees.</item>
/// </list>
/// A name from the user is never touched nor handed to another voice. Names compare case- and
/// diacritic-insensitively.
/// </remarks>
public static class SpeakerNaming
{
    /// <summary>Below this cosine similarity a voice print does not name a voice.</summary>
    public const double MinimumSimilarity = 0.55;

    /// <summary>Returns <paramref name="speakers"/> with names filled in where the evidence allows.</summary>
    public static IReadOnlyList<Speaker> Name(IReadOnlyList<Speaker> speakers, NamingCandidates candidates)
    {
        ArgumentNullException.ThrowIfNull(speakers);
        ArgumentNullException.ThrowIfNull(candidates);

        var result = speakers.ToList();
        var remote = Enumerable.Range(0, result.Count)
            .Where(i => !result[i].IsMe && result[i].Id != Speaker.OthersId)
            .ToList();

        var taken = new HashSet<string>(
            result.Where(s => s.Name is not null).Select(s => Key(s.Name!)), StringComparer.Ordinal);
        bool IsUnnamed(int index) => string.IsNullOrEmpty(result[index].Name);
        void Give(string name, int index, NameSource source)
        {
            result[index] = result[index] with { Name = name, NameSource = source };
            taken.Add(Key(name));
        }

        var window = Unique(candidates.WindowParticipants);
        var attendees = Unique(candidates.Attendees);

        // 1. Meeting window: one voice, one participant.
        if (remote.Count == 1 && window.Count == 1 && IsUnnamed(remote[0]) && !taken.Contains(Key(window[0])))
        {
            Give(window[0], remote[0], NameSource.MeetingWindow);
        }

        // 2. Voice prints.
        var unnamed = remote.Where(IsUnnamed).ToList();
        var printNames = Unique(candidates.VoicePrintSimilarity.Values
                .SelectMany(d => d.Keys)
                .Order(StringComparer.Ordinal)
                .ToList())
            .Where(n => !taken.Contains(Key(n)))
            .ToList();
        if (unnamed.Count > 0 && printNames.Count > 0)
        {
            var similarity = unnamed.Select(index => printNames.Select(name =>
                    candidates.VoicePrintSimilarity.TryGetValue(result[index].Id, out var byName)
                    && byName.TryGetValue(name, out var value) ? value : -1)
                .ToList()).ToList();
            var assignment = Hungarian.Assign([.. similarity.Select(row => (IReadOnlyList<double>)[.. row.Select(s => 1 - s)])]);
            for (var row = 0; row < assignment.Count; row++)
            {
                if (assignment[row] is not { } column || similarity[row][column] < MinimumSimilarity) continue;
                Give(printNames[column], unnamed[row], NameSource.VoicePrint);
            }
        }

        // 3. Elimination.
        var stillUnnamed = remote.Where(IsUnnamed).ToList();
        if (stillUnnamed.Count == 1)
        {
            var unusedWindow = window.Where(n => !taken.Contains(Key(n))).ToList();
            var unusedAttendees = attendees.Where(n => !taken.Contains(Key(n))).ToList();
            if (window.Count == remote.Count && unusedWindow.Count == 1)
            {
                Give(unusedWindow[0], stillUnnamed[0], NameSource.MeetingWindow);
            }
            else if (unusedAttendees.Count == 1)
            {
                Give(unusedAttendees[0], stillUnnamed[0], NameSource.Calendar);
            }
        }

        return result;
    }

    /// <summary>Cosine similarity of two embeddings; 0 when either is empty, zero, or the lengths differ.</summary>
    public static double Cosine(IReadOnlyList<float> a, IReadOnlyList<float> b)
    {
        ArgumentNullException.ThrowIfNull(a);
        ArgumentNullException.ThrowIfNull(b);
        if (a.Count != b.Count || a.Count == 0) return 0;

        double dot = 0, na = 0, nb = 0;
        for (var i = 0; i < a.Count; i++)
        {
            double x = a[i], y = b[i];
            dot += x * y;
            na += x * x;
            nb += y * y;
        }

        if (na <= 0 || nb <= 0) return 0;
        return dot / (Math.Sqrt(na) * Math.Sqrt(nb));
    }

    /// <summary>The comparison key of a name: trimmed, case- and diacritic-folded.</summary>
    public static string Key(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        var decomposed = name.Trim().Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder(decomposed.Length);
        foreach (var rune in decomposed.EnumerateRunes())
        {
            if (Rune.GetUnicodeCategory(rune) != UnicodeCategory.NonSpacingMark) builder.Append(rune.ToString());
        }

        return builder.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant();
    }

    /// <summary>Trimmed, non-empty names, first occurrence of each key kept.</summary>
    internal static List<string> Unique(IReadOnlyList<string> names)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<string>();
        foreach (var name in names)
        {
            var trimmed = name.Trim();
            if (trimmed.Length == 0 || !seen.Add(Key(trimmed))) continue;
            result.Add(trimmed);
        }

        return result;
    }
}
