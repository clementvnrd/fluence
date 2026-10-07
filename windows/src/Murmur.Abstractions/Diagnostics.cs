namespace Murmur.Abstractions;

/// <summary>How serious a diagnostic event is.</summary>
public enum LogLevel
{
    /// <summary>Something worth knowing when reading a bug report.</summary>
    Info,

    /// <summary>Something went wrong and was recovered from.</summary>
    Warning,

    /// <summary>Something went wrong and the user lost something (a dictation, a save).</summary>
    Error,
}

/// <summary>
/// A diagnostic log for failures that would otherwise vanish.
/// </summary>
/// <remarks>
/// <para>
/// Much of the dictation path runs in background tasks, where an exception that nobody awaits
/// disappears without trace. This is where those go instead.
/// </para>
/// <para>
/// <b>Never pass transcript text, dictionary entries or clipboard contents</b> — in the event
/// name, in a field, or inside an exception message you constructed. A log is the kind of file
/// that gets attached to a bug report. Field values should be counts, durations, states and
/// error codes.
/// </para>
/// </remarks>
public interface IDiagnosticLog
{
    /// <summary>Records one event.</summary>
    /// <param name="level">Severity.</param>
    /// <param name="eventName">A stable, dotted identifier such as <c>capture.open_failed</c>.</param>
    /// <param name="exception">The failure, if there was one.</param>
    /// <param name="fields">Structured context. Never text the user dictated.</param>
    void Write(
        LogLevel level,
        string eventName,
        Exception? exception = null,
        IReadOnlyDictionary<string, object?>? fields = null);
}

/// <summary>A log that discards everything. The default when none is supplied.</summary>
public sealed class NullDiagnosticLog : IDiagnosticLog
{
    /// <summary>The shared instance.</summary>
    public static NullDiagnosticLog Instance { get; } = new();

    /// <inheritdoc />
    public void Write(
        LogLevel level,
        string eventName,
        Exception? exception = null,
        IReadOnlyDictionary<string, object?>? fields = null)
    {
    }
}

/// <summary>Shorthand for the common log calls.</summary>
public static class DiagnosticLogExtensions
{
    /// <summary>Logs an error.</summary>
    public static void Error(this IDiagnosticLog log, string eventName, Exception? exception = null,
        IReadOnlyDictionary<string, object?>? fields = null) =>
        log.Write(LogLevel.Error, eventName, exception, fields);

    /// <summary>Logs a recovered problem.</summary>
    public static void Warning(this IDiagnosticLog log, string eventName, Exception? exception = null,
        IReadOnlyDictionary<string, object?>? fields = null) =>
        log.Write(LogLevel.Warning, eventName, exception, fields);

    /// <summary>Logs an informational event.</summary>
    public static void Info(this IDiagnosticLog log, string eventName,
        IReadOnlyDictionary<string, object?>? fields = null) =>
        log.Write(LogLevel.Info, eventName, null, fields);
}
