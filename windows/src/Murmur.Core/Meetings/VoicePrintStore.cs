using System.Text.Json;
using System.Text.Json.Serialization;
using Murmur.Abstractions;
using Murmur.Meeting;

namespace Murmur.Core.Meetings;

/// <summary>One enrolled voice.</summary>
public sealed record VoicePrint
{
    /// <summary>Identity, for deleting one person.</summary>
    public Guid Id { get; init; } = Guid.NewGuid();

    /// <summary>The name the user gave this voice.</summary>
    public string Name { get; init; } = string.Empty;

    /// <summary>The averaged embedding.</summary>
    public IReadOnlyList<float> Embedding { get; init; } = [];

    /// <summary>How many meetings were averaged into it.</summary>
    public int Samples { get; init; } = 1;

    /// <summary>When it last changed.</summary>
    public DateTimeOffset UpdatedAt { get; init; }
}

/// <summary>The sealed file's contents.</summary>
public sealed record VoicePrintFile
{
    /// <summary>Enrolled voices.</summary>
    public IReadOnlyList<VoicePrint> Prints { get; init; } = [];

    /// <summary>Meeting id → <c>S1…Sn</c> → embedding, kept so a rename can enrol without re-processing audio.</summary>
    public IReadOnlyDictionary<Guid, IReadOnlyDictionary<string, IReadOnlyList<float>>> Candidates { get; init; } =
        new Dictionary<Guid, IReadOnlyDictionary<string, IReadOnlyList<float>>>();
}

/// <summary>Source-generated JSON for voice prints.</summary>
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(VoicePrintFile))]
public sealed partial class VoicePrintJsonContext : JsonSerializerContext;

/// <summary>
/// Enrolled voice prints — biometric data (GDPR art. 9), so <b>opt-in, off by default</b>
/// (decision FLU-9 #3). Port of <c>VoicePrintStore.swift</c>.
/// </summary>
/// <remarks>
/// <list type="bullet">
/// <item>One file, sealed under the meetings master key (DPAPI-wrapped); never exported, never logged.</item>
/// <item>After each meeting the per-voice embeddings are kept as candidates for that meeting, so
/// renaming a voice enrols it ("confirmed by the user the first time").</item>
/// <item>While the setting is off nothing is computed, stored or matched; turning it off deletes
/// everything (<see cref="DeleteAll"/>).</item>
/// <item>Matching is restricted to calendar attendees. Windows has no calendar source yet, so
/// prints are enrolled and kept but never used to name anyone — names come from the user.</item>
/// </list>
/// </remarks>
public sealed class VoicePrintStore
{
    private const string Label = "voiceprints";

    private readonly string _path;
    private readonly MeetingVault _vault;
    private readonly Func<bool> _enabled;
    private readonly IClock _clock;
    private readonly IDiagnosticLog _log;
    private readonly Lock _sync = new();

    /// <summary>Creates the store.</summary>
    /// <param name="directory">The meetings folder.</param>
    /// <param name="vault">Seals the file.</param>
    /// <param name="enabled">The opt-in setting, read on every call.</param>
    /// <param name="clock">Stamps updates.</param>
    /// <param name="log">Exception types only.</param>
    public VoicePrintStore(string directory, MeetingVault vault, Func<bool> enabled, IClock? clock = null, IDiagnosticLog? log = null)
    {
        _path = Path.Combine(directory, "voiceprints.sealed");
        _vault = vault;
        _enabled = enabled;
        _clock = clock ?? SystemClock.Instance;
        _log = log ?? NullDiagnosticLog.Instance;
    }

    /// <summary>Whether the user has opted in.</summary>
    public bool IsEnabled => _enabled();

    /// <summary>Enrolled voices; empty while the setting is off.</summary>
    public IReadOnlyList<VoicePrint> Prints
    {
        get
        {
            if (!IsEnabled) return [];
            lock (_sync) return Load().Prints;
        }
    }

    /// <summary>Cosine similarity of each voice to each enrolled print whose name is allowed.</summary>
    public IReadOnlyDictionary<string, IReadOnlyDictionary<string, double>> Similarities(
        IReadOnlyDictionary<string, float[]> voices, IReadOnlyList<string> allowedNames)
    {
        ArgumentNullException.ThrowIfNull(voices);
        ArgumentNullException.ThrowIfNull(allowedNames);
        var allowed = new HashSet<string>(allowedNames.Select(SpeakerNaming.Key), StringComparer.Ordinal);
        var candidates = Prints.Where(p => allowed.Contains(SpeakerNaming.Key(p.Name))).ToList();
        var result = new Dictionary<string, IReadOnlyDictionary<string, double>>(StringComparer.Ordinal);
        if (candidates.Count == 0) return result;

        foreach (var (speaker, embedding) in voices)
        {
            result[speaker] = candidates.ToDictionary(p => p.Name, p => SpeakerNaming.Cosine(embedding, p.Embedding.ToArray()));
        }

        return result;
    }

    /// <summary>Keeps a meeting's voices as enrolment candidates (only while opted in).</summary>
    public void SaveCandidates(Guid meetingId, IReadOnlyDictionary<string, float[]> voices)
    {
        ArgumentNullException.ThrowIfNull(voices);
        if (!IsEnabled || voices.Count == 0) return;
        Update(file => file with
        {
            Candidates = new Dictionary<Guid, IReadOnlyDictionary<string, IReadOnlyList<float>>>(file.Candidates)
            {
                [meetingId] = voices.ToDictionary(v => v.Key, v => (IReadOnlyList<float>)v.Value, StringComparer.Ordinal),
            },
        });
    }

    /// <summary>
    /// The user named <paramref name="speakerId"/> in <paramref name="meetingId"/>: enrol (or
    /// refine, by averaging) that voice under <paramref name="name"/>.
    /// </summary>
    /// <returns>Whether a print was written.</returns>
    public bool Enroll(Guid meetingId, string speakerId, string name)
    {
        if (!IsEnabled || string.IsNullOrWhiteSpace(name)) return false;
        var written = false;
        Update(file =>
        {
            if (!file.Candidates.TryGetValue(meetingId, out var voices) || !voices.TryGetValue(speakerId, out var embedding))
            {
                return file;
            }

            var key = SpeakerNaming.Key(name);
            var prints = file.Prints.ToList();
            var index = prints.FindIndex(p => SpeakerNaming.Key(p.Name) == key);
            if (index < 0)
            {
                prints.Add(new VoicePrint { Name = name.Trim(), Embedding = [.. embedding], UpdatedAt = _clock.Now });
            }
            else
            {
                var old = prints[index];
                var averaged = old.Embedding.Count == embedding.Count
                    ? old.Embedding.Select((v, i) => ((v * old.Samples) + embedding[i]) / (old.Samples + 1)).ToList()
                    : [.. embedding];
                prints[index] = old with { Embedding = averaged, Samples = old.Samples + 1, UpdatedAt = _clock.Now };
            }

            written = true;
            return file with { Prints = prints };
        });
        return written;
    }

    /// <summary>Deletes one person's print.</summary>
    public void Delete(Guid printId) =>
        Update(file => file with { Prints = [.. file.Prints.Where(p => p.Id != printId)] });

    /// <summary>Deletes a meeting's candidates (the meeting was deleted).</summary>
    public void DeleteCandidates(Guid meetingId) =>
        Update(file => file.Candidates.ContainsKey(meetingId)
            ? file with { Candidates = file.Candidates.Where(c => c.Key != meetingId).ToDictionary(c => c.Key, c => c.Value) }
            : file);

    /// <summary>Deletes every print and candidate. Run when the setting is turned off and by "delete all".</summary>
    public void DeleteAll()
    {
        lock (_sync)
        {
            try
            {
                if (File.Exists(_path)) File.Delete(_path);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                _log.Error("voiceprints.delete_failed", e);
            }
        }
    }

    private void Update(Func<VoicePrintFile, VoicePrintFile> change)
    {
        lock (_sync)
        {
            var before = Load();
            var after = change(before);
            if (ReferenceEquals(before, after)) return;
            try
            {
                var json = JsonSerializer.SerializeToUtf8Bytes(after, VoicePrintJsonContext.Default.VoicePrintFile);
                AtomicFile.WriteAllBytes(_path, _vault.Seal(json, Label));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                _log.Error("voiceprints.write_failed", e);
            }
        }
    }

    private VoicePrintFile Load()
    {
        try
        {
            if (!File.Exists(_path)) return new VoicePrintFile();
            if (_vault.TryOpen(File.ReadAllBytes(_path), Label, out var json))
            {
                return JsonSerializer.Deserialize(json, VoicePrintJsonContext.Default.VoicePrintFile) ?? new VoicePrintFile();
            }

            _log.Warning("voiceprints.unreadable");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            _log.Error("voiceprints.read_failed", e);
        }

        return new VoicePrintFile();
    }
}
