using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using Murmur.Abstractions;
using Murmur.Meeting;

namespace Murmur.Core.Meetings;

/// <summary>
/// Encrypted on-disk store for meetings. Port of <c>MeetingStore.swift</c>.
/// </summary>
/// <remarks>
/// <para>Layout, under <c>%LOCALAPPDATA%\Fluence\meetings\</c>:</para>
/// <code>
/// meetings.key           the master key, DPAPI-wrapped (MeetingVault)
/// index.sealed           [MeetingSummary], sealed with the master key
/// voiceprints.sealed     opt-in voice prints (VoicePrintStore)
/// &lt;id&gt;\key.wrapped      the meeting's own AES-256-GCM key, wrapped by the master key
/// &lt;id&gt;\meeting.sealed   the meeting, sealed with the meeting key
/// &lt;id&gt;\audio-*.spool    the encrypted audio spool, deleted after processing unless kept
/// &lt;id&gt;\recording.marker present while recording: a meeting found with it at launch was interrupted
/// </code>
/// <para>
/// Deleting a meeting deletes its folder, wrapped key included, so any fragment left on the
/// disk is unreadable. Nothing searchable is kept in plaintext: search decrypts each meeting
/// in turn, which is fine for hundreds of meetings.
/// </para>
/// </remarks>
public sealed class MeetingStore
{
    private const string IndexLabel = "index";

    private readonly MeetingVault _vault;
    private readonly VoicePrintStore? _voicePrints;
    private readonly IDiagnosticLog _log;
    private readonly Lock _sync = new();
    private List<MeetingSummary> _summaries = [];

    /// <summary>Opens the store in <paramref name="root"/>.</summary>
    /// <param name="root">The meetings folder (the vault's folder).</param>
    /// <param name="vault">The keys.</param>
    /// <param name="voicePrints">Enrolled on rename, cleaned on delete; null without voice prints.</param>
    /// <param name="log">Exception types only — never titles, names or text.</param>
    public MeetingStore(string root, MeetingVault vault, VoicePrintStore? voicePrints, IDiagnosticLog? log = null)
    {
        Root = root;
        _vault = vault;
        _voicePrints = voicePrints;
        _log = log ?? NullDiagnosticLog.Instance;
        Directory.CreateDirectory(root);
        LoadIndex();
    }

    /// <summary>The default location.</summary>
    public static string DefaultRoot => Path.Combine(AppPaths.DataDirectory, "meetings");

    /// <summary>The meetings folder.</summary>
    public string Root { get; }

    /// <summary>Set when the index could not be read; shown in the Meetings window. Never a plaintext fallback.</summary>
    public string? LastError { get; private set; }

    /// <summary>Raised after any change, on the caller's thread.</summary>
    public event EventHandler? Changed;

    /// <summary>Newest first.</summary>
    public IReadOnlyList<MeetingSummary> Summaries
    {
        get
        {
            lock (_sync) return [.. _summaries];
        }
    }

    /// <summary>The meeting's folder.</summary>
    public string DirectoryFor(Guid id) => Path.Combine(Root, id.ToString("D"));

    /// <summary>The marker present while <paramref name="id"/> records.</summary>
    public string MarkerPath(Guid id) => Path.Combine(DirectoryFor(id), "recording.marker");

    /// <summary>The meeting's data key; the spool uses it too, so deleting the folder makes its audio unreadable.</summary>
    /// <returns>Null when the key is missing (and <paramref name="create"/> is false) or unreadable.</returns>
    public AesGcm? OpenKey(Guid id, bool create)
    {
        var path = Path.Combine(DirectoryFor(id), "key.wrapped");
        var label = id.ToString("D");
        try
        {
            if (File.Exists(path))
            {
                return _vault.TryOpenItemKey(File.ReadAllBytes(path), label, out var key) ? key : null;
            }

            if (!create) return null;
            Directory.CreateDirectory(DirectoryFor(id));
            var (fresh, wrapped) = _vault.CreateItemKey(label);
            AtomicFile.WriteAllBytes(path, wrapped);
            return fresh;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log.Error("meetings.key_failed", e);
            return null;
        }
    }

    /// <summary>Reads a meeting; null when it is missing or cannot be decrypted.</summary>
    public MeetingRecord? Load(Guid id)
    {
        using var key = OpenKey(id, create: false);
        var path = Path.Combine(DirectoryFor(id), "meeting.sealed");
        if (key is null || !File.Exists(path)) return null;
        try
        {
            if (!AeadBox.TryOpen(key, File.ReadAllBytes(path), MeetingVault.Label("meeting", id.ToString("D")), out var json))
            {
                _log.Warning("meetings.meeting_unreadable");
                return null;
            }

            return JsonSerializer.Deserialize(json, MeetingJsonContext.Default.MeetingRecord);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            _log.Error("meetings.load_failed", e);
            return null;
        }
    }

    /// <summary>Writes a meeting and its summary.</summary>
    /// <returns>False when it could not be written; the reason is in the log.</returns>
    public bool Save(MeetingRecord meeting)
    {
        ArgumentNullException.ThrowIfNull(meeting);
        using var key = OpenKey(meeting.Id, create: true);
        if (key is null) return false;
        try
        {
            var json = JsonSerializer.SerializeToUtf8Bytes(meeting, MeetingJsonContext.Default.MeetingRecord);
            AtomicFile.WriteAllBytes(Path.Combine(DirectoryFor(meeting.Id), "meeting.sealed"),
                AeadBox.Seal(key, json, MeetingVault.Label("meeting", meeting.Id.ToString("D"))));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log.Error("meetings.save_failed", e);
            return false;
        }

        lock (_sync)
        {
            _summaries.RemoveAll(s => s.Id == meeting.Id);
            _summaries.Add(new MeetingSummary(meeting));
            _summaries = [.. _summaries.OrderByDescending(s => s.StartedAt)];
            SaveIndexLocked();
        }

        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    /// <summary>
    /// Case- and accent-insensitive search over titles, speakers, the user's notes, the recap
    /// and the transcript.
    /// </summary>
    public IReadOnlyList<MeetingSummary> Search(string query)
    {
        ArgumentNullException.ThrowIfNull(query);
        var needle = query.Trim();
        var all = Summaries;
        if (needle.Length == 0) return all;
        return [.. all.Where(summary =>
        {
            if (Matches(summary.Title, needle) || summary.SpeakerNames.Any(n => Matches(n, needle))) return true;
            var meeting = Load(summary.Id);
            return meeting is not null
                && (Matches(meeting.TranscriptText, needle) || Matches(meeting.UserNotes, needle)
                    || Matches(meeting.Notes?.Recap ?? string.Empty, needle));
        })];
    }

    /// <summary>Whether <paramref name="needle"/> occurs in <paramref name="text"/>, ignoring case and accents.</summary>
    public static bool Matches(string text, string needle) =>
        CultureInfo.InvariantCulture.CompareInfo.IndexOf(text ?? string.Empty, needle,
            CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace) >= 0;

    /// <summary>
    /// Renames a speaker everywhere in a meeting and, when voice prints are on and the voice was
    /// kept as a candidate, enrols it under that name.
    /// </summary>
    public MeetingRecord? RenameSpeaker(Guid id, string speakerId, string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        var meeting = Load(id);
        if (meeting is null) return null;
        var renamed = meeting.RenameSpeaker(speakerId, name);
        if (!Save(renamed)) return null;
        if (name.Trim().Length > 0 && speakerId != Speaker.MeId) _voicePrints?.Enroll(id, speakerId, name.Trim());
        return renamed;
    }

    /// <summary>Deletes a meeting: its folder (key, transcript, audio) and its voice candidates.</summary>
    public void Delete(Guid id)
    {
        DeleteFolder(id);
        _voicePrints?.DeleteCandidates(id);
        lock (_sync)
        {
            _summaries.RemoveAll(s => s.Id == id);
            SaveIndexLocked();
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Every meeting, every spool, the index, and the voice prints. The master key stays.</summary>
    public void DeleteAll()
    {
        foreach (var folder in SafeFolders()) DeleteFolder(folder);
        _voicePrints?.DeleteAll();
        lock (_sync)
        {
            _summaries = [];
            TryDelete(Path.Combine(Root, "index.sealed"));
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Deletes meetings that started more than <paramref name="days"/> days before <paramref name="now"/>.</summary>
    /// <returns>How many were deleted.</returns>
    public int Purge(int? days, DateTimeOffset now)
    {
        if (Retention.Cutoff(days, now) is not { } cutoff) return 0;
        var expired = Summaries.Where(s => s.StartedAt < cutoff).Select(s => s.Id).ToList();
        foreach (var id in expired) Delete(id);
        if (expired.Count > 0) _log.Info("meetings.purged", new Dictionary<string, object?> { ["count"] = expired.Count });
        return expired.Count;
    }

    /// <summary>Meetings whose recording marker survived: a crash or power loss while recording.</summary>
    public IReadOnlyList<Guid> Interrupted() =>
        [.. SafeFolders().Where(id => File.Exists(MarkerPath(id)))];

    private IEnumerable<Guid> SafeFolders()
    {
        try
        {
            return [.. Directory.EnumerateDirectories(Root)
                .Select(d => Guid.TryParseExact(Path.GetFileName(d), "D", out var id) ? id : Guid.Empty)
                .Where(id => id != Guid.Empty)];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log.Error("meetings.enumerate_failed", e);
            return [];
        }
    }

    private void DeleteFolder(Guid id)
    {
        try
        {
            var folder = DirectoryFor(id);
            if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log.Error("meetings.delete_failed", e);
        }
    }

    private void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log.Error("meetings.delete_failed", e);
        }
    }

    private void LoadIndex()
    {
        var path = Path.Combine(Root, "index.sealed");
        try
        {
            if (!File.Exists(path))
            {
                // No index yet, or it was lost: rebuild it from the meetings themselves.
                if (SafeFolders().Any()) Reindex();
                return;
            }

            if (_vault.TryOpen(File.ReadAllBytes(path), IndexLabel, out var json))
            {
                _summaries = [.. (JsonSerializer.Deserialize(json, MeetingJsonContext.Default.ListMeetingSummary) ?? [])
                    .OrderByDescending(s => s.StartedAt)];
                return;
            }

            LastError = "Meetings could not be decrypted with this Windows account's key.";
            _log.Warning("meetings.index_unreadable");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            LastError = "The meetings list could not be read.";
            _log.Error("meetings.index_failed", e);
        }
    }

    private void Reindex()
    {
        var summaries = SafeFolders().Select(Load).OfType<MeetingRecord>().Select(m => new MeetingSummary(m));
        lock (_sync)
        {
            _summaries = [.. summaries.OrderByDescending(s => s.StartedAt)];
            SaveIndexLocked();
        }
    }

    private void SaveIndexLocked()
    {
        try
        {
            var json = JsonSerializer.SerializeToUtf8Bytes(_summaries, MeetingJsonContext.Default.ListMeetingSummary);
            AtomicFile.WriteAllBytes(Path.Combine(Root, "index.sealed"), _vault.Seal(json, IndexLabel));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log.Error("meetings.index_write_failed", e);
        }
    }
}
