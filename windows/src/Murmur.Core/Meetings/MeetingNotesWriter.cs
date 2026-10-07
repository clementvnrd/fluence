using Murmur.Abstractions;
using Murmur.Meeting;

namespace Murmur.Core.Meetings;

/// <summary>Writes meeting notes from a transcript. The seam where an on-device model plugs in.</summary>
public interface INotesModel
{
    /// <summary>A short name stored with the notes ("none" for <see cref="NoNotesModel"/>).</summary>
    string Name { get; }

    /// <summary>Whether a model is installed and can write notes.</summary>
    bool IsAvailable { get; }

    /// <summary>The notes for <paramref name="meeting"/>, or null when the model has nothing to say.</summary>
    /// <remarks>
    /// An implementation writes only what the transcript supports: an empty section stays empty.
    /// The transcript and the notes never leave the machine.
    /// </remarks>
    Task<FinalNotesDraft?> WriteAsync(MeetingRecord meeting, CancellationToken cancellationToken);
}

/// <summary>
/// The default on Windows: no notes model, so <b>no notes</b> — never invented. The meeting keeps
/// its transcript, speakers and the user's own notes, and the export says no notes were generated.
/// </summary>
public sealed class NoNotesModel : INotesModel
{
    /// <summary>The shared instance.</summary>
    public static NoNotesModel Instance { get; } = new();

    /// <inheritdoc />
    public string Name => "none";

    /// <inheritdoc />
    public bool IsAvailable => false;

    /// <inheritdoc />
    public Task<FinalNotesDraft?> WriteAsync(MeetingRecord meeting, CancellationToken cancellationToken) =>
        Task.FromResult<FinalNotesDraft?>(null);
}

/// <summary>Runs a notes model over a finished meeting.</summary>
public static class MeetingNotesWriter
{
    /// <summary>
    /// The meeting with notes attached when the model is available and wrote something;
    /// otherwise the meeting unchanged, with no notes.
    /// </summary>
    public static async Task<MeetingRecord> WriteAsync(
        MeetingRecord meeting, INotesModel model, IClock clock, IDiagnosticLog log, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(meeting);
        ArgumentNullException.ThrowIfNull(model);
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(log);
        if (!model.IsAvailable || meeting.Segments.Count == 0) return meeting;

        try
        {
            var draft = await model.WriteAsync(meeting, cancellationToken).ConfigureAwait(false);
            if (draft is null || draft.IsEmpty) return meeting;
            return meeting with { Notes = draft.ToNotes(clock.Now, model.Name) };
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            log.Error("meeting.notes_failed", e);
            return meeting;
        }
    }
}
