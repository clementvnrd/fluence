namespace Murmur.Meeting;

/// <summary>
/// Recognises meetings from text: browser window titles and calendar links. Port of the
/// platform-independent half of <c>MeetingApps.swift</c> (the macOS bundle-ID catalogue has a
/// Windows counterpart in <c>MeetingAppCatalog</c>).
/// </summary>
public static class MeetingTitles
{
    /// <summary>
    /// The meeting service a browser window title shows, or null when it is not a call.
    /// Conservative on purpose: a false positive only offers a card, but a noisy card gets
    /// turned off.
    /// </summary>
    public static string? MeetingService(string title)
    {
        ArgumentNullException.ThrowIfNull(title);

        var t = title.Trim(' ', '\t');
        var lower = t.ToLowerInvariant();
        if (t.StartsWith("Meet - ", StringComparison.Ordinal) || t.StartsWith("Meet – ", StringComparison.Ordinal)
            || t.StartsWith("Meet — ", StringComparison.Ordinal)
            || Has(lower, "google meet") || Has(lower, "meet.google.com"))
        {
            return "Google Meet";
        }

        if (Has(lower, "microsoft teams") || Has(lower, "teams.microsoft.com") || Has(lower, "teams.live.com"))
        {
            return "Microsoft Teams";
        }

        if (Has(lower, "zoom meeting") || Has(lower, "zoom workplace") || Has(lower, "zoom.us")
            || lower.StartsWith("zoom ", StringComparison.Ordinal))
        {
            return "Zoom";
        }

        if (Has(lower, "webex")) return "Webex";
        if (Has(lower, "whereby")) return "Whereby";
        if (Has(lower, "jitsi meet") || Has(lower, "meet.jit.si")) return "Jitsi Meet";
        if (Has(lower, "huddle") && Has(lower, "slack")) return "Slack";
        return null;
    }

    /// <summary>The conferencing service a calendar event's URL, location or notes point to.</summary>
    public static string? ConferencingService(string text)
    {
        ArgumentNullException.ThrowIfNull(text);

        var lower = text.ToLowerInvariant();
        foreach (var (needle, service) in ConferencingPatterns)
        {
            if (Has(lower, needle)) return service;
        }

        return null;
    }

    private static readonly (string Needle, string Service)[] ConferencingPatterns =
    [
        ("zoom.us/j/", "Zoom"), ("zoom.us/my/", "Zoom"), ("zoom.us/w/", "Zoom"), ("zoomgov.com/j/", "Zoom"),
        ("teams.microsoft.com/l/meetup-join", "Microsoft Teams"), ("teams.microsoft.com/meet", "Microsoft Teams"),
        ("teams.live.com/meet", "Microsoft Teams"),
        ("meet.google.com/", "Google Meet"),
        ("webex.com/meet", "Webex"), ("webex.com/join", "Webex"), ("webex.com/wbxmjs", "Webex"),
        ("whereby.com/", "Whereby"), ("meet.jit.si/", "Jitsi Meet"),
        ("facetime.apple.com/join", "FaceTime"),
        ("gotomeeting.com/join", "GoTo Meeting"), ("meet.goto.com/", "GoTo Meeting"),
        ("chime.aws/", "Amazon Chime"), ("app.slack.com/huddle", "Slack"),
    ];

    private static bool Has(string haystack, string needle) => haystack.Contains(needle, StringComparison.Ordinal);
}

/// <summary>Cleans display names read from a meeting window's participant list. Port of <c>ParticipantNames</c>.</summary>
public static class ParticipantNames
{
    /// <summary>Role and self markers Zoom, Teams and Meet append to names (EN and FR).</summary>
    private static readonly HashSet<string> Suffixes = new(StringComparer.Ordinal)
    {
        "host", "co-host", "cohost", "me", "you", "guest", "organizer", "organiser", "presenter",
        "hôte", "co-hôte", "moi", "vous", "invité", "invitée", "organisateur", "organisatrice",
        "présentateur", "external", "externe", "unverified", "non vérifié",
    };

    /// <summary>Labels of the controls around a participant list, never names.</summary>
    private static readonly HashSet<string> Controls = new(StringComparer.Ordinal)
    {
        "mute", "unmute", "mute all", "participants", "people", "invite", "chat", "raise hand",
        "lower hand", "leave", "more", "search", "close", "rename", "in this meeting",
        "in the meeting", "waiting", "contributors", "everyone", "admit", "remove", "pin",
        "spotlight", "muet", "réactiver le son", "désactiver le son", "inviter", "quitter",
        "plus", "rechercher", "fermer", "lever la main", "dans la réunion", "tout le monde",
    };

    /// <summary>Markers meaning "this row is the user".</summary>
    private static readonly HashSet<string> SelfMarkers = new(StringComparer.Ordinal) { "me", "you", "moi", "vous" };

    /// <summary>
    /// Cleaned, de-duplicated names in their original order: trailing "(…)" role markers are
    /// stripped, the row marked as the user is dropped, as are control labels, strings shorter
    /// than 2 or longer than 60 characters, anything without a letter, and names matching
    /// <paramref name="excluding"/> (case- and diacritic-insensitively).
    /// </summary>
    public static IReadOnlyList<string> Clean(IReadOnlyList<string> raw, IReadOnlyList<string>? excluding = null)
    {
        ArgumentNullException.ThrowIfNull(raw);

        var excluded = new HashSet<string>((excluding ?? []).Select(SpeakerNaming.Key), StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<string>();

        foreach (var value in raw)
        {
            var name = value.Trim();
            var isSelf = false;

            // Peel off "(…)" groups made only of role markers.
            while (name.EndsWith(')') && name.LastIndexOf('(') is var open and >= 0)
            {
                var parts = name[(open + 1)..^1].Split(',')
                    .Select(p => p.Trim(' ', '\t').ToLowerInvariant())
                    .ToList();
                if (parts.Count == 0 || !parts.All(Suffixes.Contains)) break;
                if (parts.Any(SelfMarkers.Contains)) isSelf = true;
                name = name[..open].Trim(' ', '\t');
            }

            var length = name.EnumerateRunes().Count();
            if (isSelf || length < 2 || length > 60
                || !name.EnumerateRunes().Any(System.Text.Rune.IsLetter)
                || Controls.Contains(name.ToLowerInvariant())
                || excluded.Contains(SpeakerNaming.Key(name))
                || !seen.Add(SpeakerNaming.Key(name)))
            {
                continue;
            }

            result.Add(name);
        }

        return result;
    }
}
