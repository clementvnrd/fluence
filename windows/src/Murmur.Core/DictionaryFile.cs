using Murmur.Abstractions;
using Murmur.Dictionary;

namespace Murmur.Core;

/// <summary>
/// The dictionary, persisted as a plain text file you can edit by hand.
/// </summary>
/// <remarks>
/// <para>
/// A text file rather than JSON, because the point is that it's editable outside the UI and
/// JSON is only nominally that — quoting, escaping, and a trailing-comma trap for anyone
/// adding a line in a hurry. One entry per line:
/// </para>
/// <code>
/// Anthropic
/// Vercel
/// cloud code -> Claude Code
/// # off: whisper flow -> Wispr Flow
/// </code>
/// <para>
/// A bare line is a term, <c>X -> Y</c> is a correction, <c>#</c> starts a comment, and a
/// disabled entry is written as <c># off:</c> so it survives a round trip rather than
/// silently disappearing.
/// </para>
/// <para>
/// <b>The file is the user's.</b> Comments, blank lines and lines this parser does not
/// understand are kept exactly where they are when the app saves; only the entry lines it
/// manages are rewritten. Saves are atomic. External edits are picked up while the app runs
/// (<see cref="StartWatching"/>) — including editors that save by deleting and renaming, which
/// briefly leave no file at all: a missing file never empties the in-memory dictionary, so the
/// next in-app edit cannot overwrite the user's work with nothing.
/// </para>
/// <para>
/// <b>Thread-safe.</b> <see cref="Entries"/> is an immutable snapshot, replaced atomically, so
/// the dictation engine can read it from its own thread while the UI edits.
/// </para>
/// <para>
/// Byte-compatible with the macOS build's <c>dictionary.txt</c>: the same file works on both.
/// </para>
/// </remarks>
public sealed class DictionaryFile : IDisposable
{
    private const string DisabledPrefix = "off:";
    private const string Arrow = "->";

    /// <summary>How long to wait for an external editor to finish before re-reading.</summary>
    public static readonly TimeSpan ReloadDebounce = TimeSpan.FromMilliseconds(250);

    private readonly string _path;
    private readonly IDiagnosticLog _log;
    private readonly Lock _sync = new();

    /// <summary>The file, line by line: either an entry this class manages, or raw text it keeps.</summary>
    private List<Line> _lines = [];

    private DictionaryEntry[] _snapshot = [];

    /// <summary>What the file held when last read or written. Used to ignore our own saves.</summary>
    private string? _lastText;

    private FileSystemWatcher? _watcher;
    private Timer? _debounce;
    private bool _disposed;

    private sealed record Line(string? Raw, DictionaryEntry? Entry);

    /// <summary>Opens the dictionary at <paramref name="path"/>. The file is created on first save.</summary>
    public DictionaryFile(string path, IDiagnosticLog? log = null)
    {
        _path = path;
        _log = log ?? NullDiagnosticLog.Instance;
        Reload();
    }

    /// <summary>The default location, alongside the transcript history.</summary>
    public static string DefaultPath => AppPaths.DictionaryFile;

    /// <summary>
    /// Where this dictionary lives on disk.
    /// </summary>
    /// <remarks>
    /// Not named <c>Path</c>: that would shadow <see cref="System.IO.Path"/> inside this
    /// class, breaking every static call to it.
    /// </remarks>
    public string FilePath => _path;

    /// <summary>Every entry, in file order. An immutable snapshot, safe from any thread.</summary>
    public IReadOnlyList<DictionaryEntry> Entries => Volatile.Read(ref _snapshot);

    /// <summary>Raised whenever the entries change. May be raised on any thread.</summary>
    public event EventHandler? Changed;

    /// <summary>Re-reads the file, discarding in-memory state.</summary>
    public void Reload()
    {
        bool changed;
        lock (_sync)
        {
            changed = RefreshLocked(force: true);
        }

        if (changed) Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Re-reads the file whenever another program changes it, until disposed.
    /// </summary>
    public void StartWatching()
    {
        lock (_sync)
        {
            if (_watcher is not null || _disposed) return;

            var directory = Path.GetDirectoryName(Path.GetFullPath(_path))!;
            Directory.CreateDirectory(directory);

            _debounce = new Timer(_ => OnExternalChange(), null, Timeout.Infinite, Timeout.Infinite);
            _watcher = new FileSystemWatcher(directory, Path.GetFileName(_path))
            {
                NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size,
            };

            _watcher.Changed += OnFileEvent;
            _watcher.Created += OnFileEvent;
            _watcher.Renamed += OnFileEvent;
            _watcher.Deleted += OnFileEvent;
            _watcher.Error += (_, e) => _log.Warning("dictionary.watch_error", e.GetException());
            _watcher.EnableRaisingEvents = true;
        }
    }

    // Editors fire several events per save; wait for the burst to finish.
    private void OnFileEvent(object sender, FileSystemEventArgs e) =>
        _debounce?.Change(ReloadDebounce, Timeout.InfiniteTimeSpan);

    private void OnExternalChange()
    {
        bool changed;
        lock (_sync)
        {
            if (_disposed) return;
            changed = RefreshLocked(force: false);
        }

        if (changed) Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Brings the in-memory document in line with the file. Caller holds <see cref="_sync"/>.
    /// </summary>
    /// <returns>True if the entries changed.</returns>
    private bool RefreshLocked(bool force)
    {
        string? text;
        try
        {
            text = File.Exists(_path) ? File.ReadAllText(_path) : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Usually an editor holding the file mid-save. Keep what we have; the watcher
            // fires again when the editor lets go.
            _log.Warning("dictionary.read_failed", e);
            return false;
        }

        if (text is null)
        {
            // Missing. On first open that simply means "empty". Afterwards it is most likely
            // an editor between delete and rename — keep the entries rather than wiping them.
            if (!force || _lastText is not null) return false;
            _lines = [];
            _lastText = null;
            return Publish();
        }

        if (!force && text == _lastText) return false;

        _lines = ParseDocument(text, Entries);
        _lastText = text;
        return Publish();
    }

    /// <summary>Parses the file format into entries, ignoring everything else.</summary>
    public static List<DictionaryEntry> Parse(string text) =>
        ParseDocument(text, []).Where(l => l.Entry is not null).Select(l => l.Entry!).ToList();

    /// <summary>
    /// Parses every line, keeping the ones that are not entries verbatim. Entries identical to
    /// one in <paramref name="previous"/> keep its <see cref="DictionaryEntry.Id"/>, so the UI's
    /// references survive an external reload.
    /// </summary>
    private static List<Line> ParseDocument(string text, IReadOnlyList<DictionaryEntry> previous)
    {
        var reusable = previous.ToList();
        var lines = new List<Line>();

        // Any line ending ends a line: \n, \r\n, or a lone \r (the shared vectors' fileCases).
        var raw = text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Split('\n');
        var count = raw.Length;
        if (count > 0 && raw[^1].Length == 0) count--;   // the final newline is not a line

        for (var i = 0; i < count; i++)
        {
            var entry = ParseLine(raw[i]);
            if (entry is null)
            {
                lines.Add(new Line(raw[i], null));
                continue;
            }

            var match = reusable.FindIndex(e => e.ToFileLine() == entry.ToFileLine());
            if (match >= 0)
            {
                entry = entry with { Id = reusable[match].Id };
                reusable.RemoveAt(match);
            }

            lines.Add(new Line(null, entry));
        }

        return lines;
    }

    private static DictionaryEntry? ParseLine(string raw)
    {
        var line = raw.Trim();
        if (line.Length == 0) return null;

        var enabled = true;
        if (line.StartsWith('#'))
        {
            var stripped = line[1..].Trim();
            if (!stripped.StartsWith(DisabledPrefix, StringComparison.OrdinalIgnoreCase)) return null;

            line = stripped[DisabledPrefix.Length..].Trim();
            enabled = false;
            if (line.Length == 0) return null;
        }

        var arrow = line.IndexOf(Arrow, StringComparison.Ordinal);
        if (arrow >= 0)
        {
            var hear = line[..arrow].Trim();
            var write = line[(arrow + Arrow.Length)..].Trim();
            if (hear.Length == 0 || write.Length == 0) return null;

            return new DictionaryEntry
            {
                Kind = EntryKind.Correction, Hear = hear, Write = write, IsEnabled = enabled,
            };
        }

        return new DictionaryEntry { Kind = EntryKind.Term, Write = line, IsEnabled = enabled };
    }

    /// <summary>Adds an entry and saves.</summary>
    public void Add(DictionaryEntry entry) => Mutate(lines =>
    {
        if (lines.Count == 0) lines.AddRange(Header.Select(h => new Line(h, null)));
        lines.Add(new Line(null, entry));
        return true;
    });

    /// <summary>Replaces an entry by id and saves.</summary>
    public void Update(DictionaryEntry entry) => Mutate(lines =>
    {
        var index = lines.FindIndex(l => l.Entry?.Id == entry.Id);
        if (index < 0) return false;

        lines[index] = new Line(null, entry);
        return true;
    });

    /// <summary>Removes an entry and saves.</summary>
    public void Remove(Guid id) => Mutate(lines => lines.RemoveAll(l => l.Entry?.Id == id) > 0);

    /// <summary>Case-insensitive search across both sides of an entry.</summary>
    public IReadOnlyList<DictionaryEntry> Search(string query)
    {
        var entries = Entries;
        var trimmed = query.Trim();
        if (trimmed.Length == 0) return entries;

        return entries.Where(e =>
            e.Write.Contains(trimmed, StringComparison.OrdinalIgnoreCase) ||
            e.Hear.Contains(trimmed, StringComparison.OrdinalIgnoreCase)).ToList();
    }

    private void Mutate(Func<List<Line>, bool> change)
    {
        lock (_sync)
        {
            // Pick up an external edit the watcher has not delivered yet, so this save builds
            // on the user's latest file rather than overwriting it.
            RefreshLocked(force: false);

            var lines = new List<Line>(_lines);
            if (!change(lines)) return;

            var text = Render(lines);
            _lines = lines;
            Publish();

            try
            {
                AtomicFile.WriteAllText(_path, text);
                _lastText = text;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Kept in memory (and used for dictation); the next successful save writes it.
                _log.Error("dictionary.save_failed", e);
            }
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static string Render(List<Line> lines) =>
        string.Concat(lines.Select(l => (l.Entry?.ToFileLine() ?? l.Raw) + "\n"));

    /// <returns>True if the entries differ from the previous snapshot.</returns>
    private bool Publish()
    {
        var next = _lines.Where(l => l.Entry is not null).Select(l => l.Entry!).ToArray();
        var previous = Volatile.Read(ref _snapshot);
        Volatile.Write(ref _snapshot, next);
        return !previous.SequenceEqual(next);
    }

    private static readonly string[] Header =
    [
        "# Fluence dictionary",
        "#",
        "#   Anthropic                 a term — the engine is told this word exists",
        "#   cloud code -> Claude Code a correction — when you hear X, write Y",
        "#   # off: some rule -> Rule  a disabled entry",
        "#",
        "# Edit this file directly if you like; Fluence picks up changes while it runs.",
        "",
    ];

    /// <inheritdoc />
    public void Dispose()
    {
        lock (_sync)
        {
            _disposed = true;
            _watcher?.Dispose();
            _watcher = null;
            _debounce?.Dispose();
            _debounce = null;
        }
    }
}
