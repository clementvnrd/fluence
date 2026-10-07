using Murmur.Core;

namespace Murmur.App.Views;

/// <summary>How the model's state is put into words, in Settings and on the main window.</summary>
/// <param name="Headline">One short line.</param>
/// <param name="Detail">What to do about it, or where it was loaded from.</param>
/// <param name="IsReady">Drives the lamp: green and lit only when the model really loaded.</param>
/// <param name="NeedsAttention">Whether the main window should show a banner.</param>
public sealed record ModelStatus(string Headline, string Detail, bool IsReady, bool NeedsAttention)
{
    /// <summary>Describes <paramref name="state"/>.</summary>
    /// <param name="state">The host's state.</param>
    /// <param name="detail">The host's failure explanation, if any.</param>
    /// <param name="location">Where the model was found, if anywhere.</param>
    /// <param name="searched">Every directory that was checked, for the "not installed" case.</param>
    public static ModelStatus Describe(
        ModelState state, string? detail, string? location, IEnumerable<string> searched) => state switch
    {
        ModelState.Ready => new("Parakeet loaded", $"Loaded from {location}", true, false),

        ModelState.Loading => new("Loading Parakeet…",
            $"Verifying and loading from {location}. This takes a few seconds, once per launch.", false, false),

        ModelState.NotLoaded => new("Parakeet found, not loaded yet",
            $"Found in {location}. It loads on first use.", false, false),

        ModelState.Failed => new("Parakeet failed to load",
            (detail ?? "Unknown error.") + $"\n\nModel folder: {location}\nSee docs/PARAKEET-WINDOWS.md → Troubleshooting.",
            false, true),

        // Showing every checked path matters: "model not found" is unactionable without
        // knowing which directories were actually looked in.
        _ => new("Model not installed",
            "Windows has no built-in speech engine equivalent to Apple's, so Fluence cannot "
            + "transcribe until the Parakeet model is downloaded (~661 MB). See "
            + "docs/PARAKEET-WINDOWS.md. Looked in:\n" + string.Join("\n", searched),
            false, true),
    };
}
