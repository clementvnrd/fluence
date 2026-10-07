using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Murmur.Abstractions;
using Murmur.Dictionary;

namespace Murmur.Core;

/// <summary>One saved dictation.</summary>
public sealed record TranscriptRecord
{
    /// <summary>Stable identity, so one entry can be deleted without matching on its text.</summary>
    public Guid Id { get; init; } = Guid.NewGuid();

    /// <summary>When the key was released.</summary>
    public DateTimeOffset At { get; init; }

    /// <summary>How long the key was held.</summary>
    public double AudioSeconds { get; init; }

    /// <summary>Release to finished text — the wait actually felt.</summary>
    public double ProcessingSeconds { get; init; }

    /// <summary>The final text, after corrections.</summary>
    public string Text { get; init; } = string.Empty;

    /// <summary>
    /// What the speech engine heard, before the dictionary ran. Null in records written before
    /// it was kept, or when it is identical to <see cref="Text"/>.
    /// </summary>
    /// <remarks>
    /// Kept so a correction that went wrong can be seen for what it was, and so nothing the
    /// user said is lost to a rule that over-matched.
    /// </remarks>
    public string? RawText { get; init; }

    /// <summary>Corrections that fired, if any.</summary>
    public IReadOnlyList<AppliedCorrection>? Corrections { get; init; }
}

/// <summary>How long the transcript history keeps a dictation.</summary>
public enum HistoryRetention
{
    /// <summary>Keep nothing. Existing history is deleted.</summary>
    Never,

    /// <summary>Keep the last 24 hours.</summary>
    OneDay,

    /// <summary>Keep the last 30 days. The default.</summary>
    ThirtyDays,

    /// <summary>Keep everything until deleted by hand.</summary>
    Forever,
}

/// <summary>Helpers for <see cref="HistoryRetention"/>.</summary>
public static class HistoryRetentionExtensions
{
    /// <summary>The oldest a record may be, or null for no limit.</summary>
    public static TimeSpan? MaxAge(this HistoryRetention retention) => retention switch
    {
        HistoryRetention.Never => TimeSpan.Zero,
        HistoryRetention.OneDay => TimeSpan.FromDays(1),
        HistoryRetention.ThirtyDays => TimeSpan.FromDays(30),
        _ => null,
    };
}

/// <summary>
/// Transcript history: one sealed JSON object per line, encrypted at rest.
/// </summary>
/// <remarks>
/// <para>
/// One record per line rather than one big array: appending is cheap and a torn write costs
/// one record rather than the whole file. Every line is sealed by <see cref="HistoryCipher"/>
/// under a key wrapped for the current user (DPAPI on Windows); the file on disk never holds
/// a dictation in the clear.
/// </para>
/// <para>
/// <b>Migration.</b> Histories written before sealing are plaintext JSON lines. They are read
/// once, the file is atomically rewritten sealed, and the plaintext is gone from the file.
/// (The old blocks are not wiped — on an SSD they cannot reliably be — so a forensic copy of
/// the disk taken before migration could still hold them.)
/// </para>
/// <para>
/// <b>No secure storage, no disk.</b> Without an <see cref="ISecretProtector"/> — off Windows,
/// or when the platform layer failed to load — the history lives in memory only, rather than
/// quietly falling back to plaintext.
/// </para>
/// <para>
/// Serialization is source-generated (<see cref="TranscriptJsonContext"/>) so this survives
/// trimming and single-file publishing, where reflection-based JSON quietly stops working.
/// </para>
/// </remarks>
public sealed class TranscriptStore : IDisposable
{
    private readonly string _path;
    private readonly IDiagnosticLog _log;
    private readonly HistoryCipher? _cipher;
    private readonly Lock _sync = new();

    /// <summary>Newest first.</summary>
    private readonly List<TranscriptRecord> _records = [];

    /// <summary>Sealed lines that could not be opened. Kept verbatim on rewrite, never guessed at.</summary>
    private readonly List<string> _unreadable = [];

    private TranscriptRecord[] _snapshot = [];

    /// <summary>
    /// Opens the history at <paramref name="path"/>, sealing it with a key wrapped by
    /// <paramref name="protector"/>.
    /// </summary>
    /// <param name="path">The history file.</param>
    /// <param name="protector">
    /// Wraps the data key. Null keeps the history in memory only.
    /// </param>
    /// <param name="log">Where failures are reported. Never receives transcript text.</param>
    /// <param name="clock">Time source, for naming set-aside files.</param>
    public TranscriptStore(string path, ISecretProtector? protector, IDiagnosticLog? log = null, IClock? clock = null)
    {
        _path = path;
        _log = log ?? NullDiagnosticLog.Instance;

        if (protector is null)
        {
            Problem = "History is kept in memory only: no secure key storage is available.";
        }
        else
        {
            _cipher = OpenCipher(protector, clock ?? SystemClock.Instance);
        }

        Reload();
    }

    /// <summary>The default location.</summary>
    public static string DefaultPath => AppPaths.TranscriptsFile;

    /// <summary>Where the wrapped data key for <paramref name="historyPath"/> lives.</summary>
    public static string KeyPathFor(string historyPath) => Path.ChangeExtension(historyPath, ".key");

    /// <summary>Whether records are written to disk (sealed).</summary>
    public bool IsPersistent => _cipher is not null;

    /// <summary>A user-facing explanation when something is wrong with the history, else null.</summary>
    public string? Problem { get; private set; }

    /// <summary>Every record, newest first. A snapshot: safe to enumerate from any thread.</summary>
    public IReadOnlyList<TranscriptRecord> Records => Volatile.Read(ref _snapshot);

    /// <summary>Raised whenever the history changes. May be raised on any thread.</summary>
    public event EventHandler? Changed;

    private HistoryCipher? OpenCipher(ISecretProtector protector, IClock clock)
    {
        var keyPath = KeyPathFor(_path);

        try
        {
            return HistoryCipher.OpenOrCreate(keyPath, protector);
        }
        catch (CryptographicException e)
        {
            // The key cannot be unwrapped: another Windows account, a reset profile, or damage.
            // The history it sealed is unreadable to us — but not necessarily to its owner, so
            // set both files aside rather than deleting anything, and start afresh.
            _log.Error("history.key_unreadable", e);
            var stamp = clock.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
            SetAside(keyPath, stamp);
            SetAside(_path, stamp);
            Problem = "The previous history could not be unlocked by this Windows account. "
                    + "It was kept, set aside, and a new history was started.";
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log.Error("history.key_io_failed", e);
            Problem = "The history key could not be read, so history is kept in memory only.";
            return null;
        }

        try
        {
            return HistoryCipher.OpenOrCreate(keyPath, protector);
        }
        catch (Exception e) when (e is CryptographicException or IOException or UnauthorizedAccessException)
        {
            _log.Error("history.key_create_failed", e);
            Problem = "A history key could not be created, so history is kept in memory only.";
            return null;
        }
    }

    private void SetAside(string path, string stamp)
    {
        if (!File.Exists(path)) return;

        var directory = Path.GetDirectoryName(path)!;
        var target = Path.Combine(directory,
            $"{Path.GetFileNameWithoutExtension(path)}.unreadable-{stamp}{Path.GetExtension(path)}");

        try
        {
            File.Move(path, target, overwrite: false);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log.Error("history.set_aside_failed", e);
        }
    }

    /// <summary>Re-reads the file, migrating plaintext lines to sealed ones.</summary>
    public void Reload()
    {
        lock (_sync)
        {
            _records.Clear();
            _unreadable.Clear();

            if (_cipher is not null && File.Exists(_path))
            {
                var plaintextLines = 0;

                try
                {
                    foreach (var line in File.ReadLines(_path))
                    {
                        if (string.IsNullOrWhiteSpace(line)) continue;

                        if (HistoryCipher.IsSealed(line))
                        {
                            if (_cipher.TryOpen(line, out var json) && TryParse(json) is { } sealedRecord)
                            {
                                _records.Add(sealedRecord);
                            }
                            else
                            {
                                _unreadable.Add(line);
                            }

                            continue;
                        }

                        // A pre-sealing plaintext line. Kept if it parses; dropped either way
                        // from the file, which is about to be rewritten without plaintext.
                        plaintextLines++;
                        if (TryParse(line) is { } legacy) _records.Add(legacy);
                    }
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    _log.Error("history.read_failed", e);
                }

                _records.Reverse();   // newest first, which is how the list reads

                if (plaintextLines > 0)
                {
                    RewriteLocked();
                    _log.Info("history.plaintext_migrated", new Dictionary<string, object?>
                    {
                        ["lines"] = plaintextLines,
                        ["kept"] = _records.Count,
                    });
                }

                if (_unreadable.Count > 0)
                {
                    _log.Warning("history.lines_unreadable", fields: new Dictionary<string, object?>
                    {
                        ["lines"] = _unreadable.Count,
                    });
                }
            }

            Publish();
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    // A single corrupt line must not destroy the whole history — skip it and keep the rest.
    private static TranscriptRecord? TryParse(string json)
    {
        try
        {
            return JsonSerializer.Deserialize(json, TranscriptJsonContext.Default.TranscriptRecord);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>Appends a record.</summary>
    public void Add(TranscriptRecord record)
    {
        lock (_sync)
        {
            _records.Insert(0, record);
            Publish();

            if (_cipher is not null)
            {
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_path))!);
                    var line = JsonSerializer.Serialize(record, TranscriptJsonContext.Default.TranscriptRecord);
                    File.AppendAllText(_path, _cipher.Seal(line) + "\n", AtomicFile.Utf8);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    _log.Error("history.append_failed", e);
                }
            }
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Deletes one record.</summary>
    public void Remove(Guid id)
    {
        lock (_sync)
        {
            if (_records.RemoveAll(r => r.Id == id) == 0) return;
            RewriteLocked();
            Publish();
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Deletes everything, including lines that could not be read.</summary>
    public void Clear()
    {
        lock (_sync)
        {
            _records.Clear();
            _unreadable.Clear();
            RewriteLocked();
            Publish();
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Deletes every record older than <paramref name="retention"/> allows. Run at startup,
    /// after every dictation, and whenever the setting changes.
    /// </summary>
    /// <returns>How many records were deleted.</returns>
    public int ApplyRetention(HistoryRetention retention, DateTimeOffset now)
    {
        var maxAge = retention.MaxAge();
        if (maxAge is null) return 0;

        int removed;
        lock (_sync)
        {
            if (retention == HistoryRetention.Never)
            {
                removed = _records.Count + _unreadable.Count;
                _records.Clear();
                _unreadable.Clear();
            }
            else
            {
                var cutoff = now - maxAge.Value;
                removed = _records.RemoveAll(r => r.At < cutoff);
            }

            if (removed == 0) return 0;

            RewriteLocked();
            Publish();
        }

        Changed?.Invoke(this, EventArgs.Empty);
        return removed;
    }

    /// <summary>Case-insensitive search over transcript text.</summary>
    public IReadOnlyList<TranscriptRecord> Search(string query)
    {
        var records = Records;
        var trimmed = query.Trim();
        if (trimmed.Length == 0) return records;

        return records
            .Where(r => r.Text.Contains(trimmed, StringComparison.OrdinalIgnoreCase))
            .ToList();
    }

    private void Publish() => Volatile.Write(ref _snapshot, [.. _records]);

    /// <summary>Atomically replaces the file. Caller holds <see cref="_sync"/>.</summary>
    private void RewriteLocked()
    {
        if (_cipher is null) return;

        try
        {
            if (_records.Count == 0 && _unreadable.Count == 0)
            {
                if (File.Exists(_path)) File.Delete(_path);
                return;
            }

            // Oldest first on disk, so a plain append stays correct next time.
            var lines = _unreadable.Concat(
                Enumerable.Reverse(_records).Select(r => _cipher.Seal(
                    JsonSerializer.Serialize(r, TranscriptJsonContext.Default.TranscriptRecord))));

            AtomicFile.WriteAllLines(_path, lines);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log.Error("history.rewrite_failed", e);
        }
    }

    /// <inheritdoc />
    public void Dispose() => _cipher?.Dispose();
}

/// <summary>
/// Source-generated JSON for the transcript store.
/// </summary>
/// <remarks>
/// Reflection-based serialization breaks under trimming and is flagged by the single-file
/// analyzer. Generating it keeps the published binary honest.
/// </remarks>
[JsonSourceGenerationOptions(WriteIndented = false, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(TranscriptRecord))]
[JsonSerializable(typeof(AppliedCorrection))]
public sealed partial class TranscriptJsonContext : JsonSerializerContext;
