using System.Globalization;
using System.Text;
using System.Text.Json;
using Murmur.Abstractions;

namespace Murmur.Core;

/// <summary>
/// Writes diagnostic events as JSON lines under <c>%LOCALAPPDATA%\Fluence\logs</c>, rotating
/// by size.
/// </summary>
/// <remarks>
/// <para>
/// One object per line: a timestamp, a level, an event name, optional exception details
/// (type, HRESULT, message, stack) and optional fields. Nothing else — in particular no
/// transcript text, which callers are forbidden to pass (see <see cref="IDiagnosticLog"/>).
/// </para>
/// <para>
/// Writing a log must never be the thing that breaks the app, so every I/O failure here is
/// swallowed. Rotation keeps <see cref="KeptFiles"/> files of at most
/// <see cref="MaxBytes"/> each, so the folder cannot grow without bound.
/// </para>
/// </remarks>
public sealed class FileDiagnosticLog : IDiagnosticLog
{
    /// <summary>Size at which the current file is rotated.</summary>
    public const long MaxBytes = 512 * 1024;

    /// <summary>How many files are kept, the current one included.</summary>
    public const int KeptFiles = 3;

    /// <summary>The current file's name.</summary>
    public const string FileName = "fluence.log";

    private readonly string _directory;
    private readonly IClock _clock;
    private readonly Lock _sync = new();

    /// <summary>Logs into <paramref name="directory"/>, created on first write.</summary>
    public FileDiagnosticLog(string directory, IClock? clock = null)
    {
        _directory = directory;
        _clock = clock ?? SystemClock.Instance;
    }

    /// <summary>The file currently being written.</summary>
    public string CurrentPath => Path.Combine(_directory, FileName);

    /// <inheritdoc />
    public void Write(
        LogLevel level,
        string eventName,
        Exception? exception = null,
        IReadOnlyDictionary<string, object?>? fields = null)
    {
        string line;
        try
        {
            line = Format(_clock.Now, level, eventName, exception, fields);
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or NotSupportedException)
        {
            return;
        }

        lock (_sync)
        {
            try
            {
                Directory.CreateDirectory(_directory);
                RotateIfNeeded();
                File.AppendAllText(CurrentPath, line + "\n", Encoding.UTF8);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // A log that cannot be written is not worth crashing over.
            }
        }
    }

    private void RotateIfNeeded()
    {
        var current = new FileInfo(CurrentPath);
        if (!current.Exists || current.Length < MaxBytes) return;

        for (var i = KeptFiles - 1; i >= 1; i--)
        {
            var from = i == 1 ? CurrentPath : Rotated(i - 1);
            var to = Rotated(i);
            if (File.Exists(from)) File.Move(from, to, overwrite: true);
        }
    }

    private string Rotated(int index) =>
        Path.Combine(_directory, string.Create(CultureInfo.InvariantCulture, $"fluence.{index}.log"));

    /// <summary>Renders one event as a single JSON line.</summary>
    public static string Format(
        DateTimeOffset at,
        LogLevel level,
        string eventName,
        Exception? exception,
        IReadOnlyDictionary<string, object?>? fields)
    {
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer))
        {
            json.WriteStartObject();
            json.WriteString("t", at.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture));
            json.WriteString("level", level.ToString().ToLowerInvariant());
            json.WriteString("event", eventName);

            if (exception is not null)
            {
                json.WriteString("exception", exception.GetType().FullName);
                json.WriteString("hresult", string.Create(
                    CultureInfo.InvariantCulture, $"0x{exception.HResult:X8}"));
                json.WriteString("message", exception.Message);
                if (exception.InnerException is { } inner)
                {
                    json.WriteString("inner", inner.GetType().FullName);
                    json.WriteString("innerMessage", inner.Message);
                }
                if (exception.StackTrace is { } stack) json.WriteString("stack", stack);
            }

            if (fields is not null)
            {
                foreach (var (key, value) in fields)
                {
                    switch (value)
                    {
                        case null: json.WriteNull(key); break;
                        case bool b: json.WriteBoolean(key, b); break;
                        case int i: json.WriteNumber(key, i); break;
                        case long l: json.WriteNumber(key, l); break;
                        case double d: json.WriteNumber(key, d); break;
                        case float f: json.WriteNumber(key, f); break;
                        case TimeSpan span: json.WriteNumber(key, Math.Round(span.TotalMilliseconds)); break;
                        case IFormattable formattable:
                            json.WriteString(key, formattable.ToString(null, CultureInfo.InvariantCulture));
                            break;
                        default: json.WriteString(key, value.ToString()); break;
                    }
                }
            }

            json.WriteEndObject();
        }

        return Encoding.UTF8.GetString(buffer.ToArray());
    }
}
