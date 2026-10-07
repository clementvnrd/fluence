using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Murmur.App.Controls;
using Murmur.App.Design;
using Murmur.Core;
using Murmur.Core.Meetings;
using Murmur.Meeting;

namespace Murmur.App.Views;

/// <summary>
/// Past meetings: a searchable list, and the selected meeting's notes, speakers and transcript,
/// with rename, Copy as Markdown, Export and Delete.
/// </summary>
/// <remarks>
/// <para>
/// Search decrypts each meeting in turn (nothing searchable is stored in plaintext), so it runs
/// off the UI thread, a quarter second after the last keystroke.
/// </para>
/// <para>
/// Without a notes model there are no notes, and the view says so rather than showing an empty
/// recap that could pass for "nothing was said".
/// </para>
/// </remarks>
public sealed class MeetingsView : UserControl
{
    private readonly MeetingStore? _store;
    private readonly TextBox _search = Panels.SearchBox("Search meetings: titles, speakers, transcripts");
    private readonly StackPanel _list = new() { Spacing = Tokens.Space.Tight, Margin = new Thickness(Tokens.Space.Snug) };
    private readonly StackPanel _detail = new() { Spacing = Tokens.Space.Base, Margin = new Thickness(Tokens.Space.Base) };
    private readonly Silkscreen _count = new() { Foreground = new SolidColorBrush(Tokens.Colors.InkOnDeck, 0.5) };
    private readonly Button _deleteAll = Panels.DeckButton("DELETE ALL");
    private readonly DispatcherTimer _searchDelay = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private IReadOnlyList<MeetingSummary> _shown = [];
    private int _searchGeneration;
    private bool _confirmingDeleteAll;

    /// <summary>Builds the view over <paramref name="store"/>; null shows <paramref name="problem"/>.</summary>
    public MeetingsView(MeetingStore? store, string? problem = null)
    {
        _store = store;
        Problem = store?.LastError ?? (store is null ? problem ?? "Meetings are not available." : null);

        _search.TextChanged += (_, _) =>
        {
            _searchDelay.Stop();
            _searchDelay.Start();
        };
        _searchDelay.Tick += (_, _) =>
        {
            _searchDelay.Stop();
            _ = SearchAsync();
        };
        _deleteAll.Click += (_, _) => DeleteAll();

        var consentFr = Panels.DeckButton("CONSENT FR");
        var consentEn = Panels.DeckButton("CONSENT EN");
        consentFr.Click += (_, _) => _ = CopyAsync(ConsentNotice.Text(NotesLanguage.French), consentFr);
        consentEn.Click += (_, _) => _ = CopyAsync(ConsentNotice.Text(NotesLanguage.English), consentEn);
        ToolTip.SetTip(consentFr, ConsentNotice.Text(NotesLanguage.French));
        ToolTip.SetTip(consentEn, ConsentNotice.Text(NotesLanguage.English));

        var listPane = new ScrollViewer { Content = _list, Width = 260 };
        DockPanel.SetDock(listPane, Dock.Left);

        Content = new DockPanel
        {
            Children =
            {
                Panels.Docked(Panels.SearchRow(_search, new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = Tokens.Space.Tight,
                    Children = { consentFr, consentEn },
                }), Dock.Top),
                Panels.Docked(Panels.Footer(_count, _deleteAll), Dock.Bottom),
                listPane,
                new Border
                {
                    BorderBrush = new SolidColorBrush(Tokens.Colors.Seam),
                    BorderThickness = new Thickness(Tokens.Border.Seam, 0, 0, 0),
                    Child = new ScrollViewer { Content = _detail },
                },
            },
        };

        if (_store is not null) _store.Changed += (_, _) => Dispatcher.UIThread.Post(() => _ = SearchAsync());
        Show(_store?.Summaries ?? []);
    }

    /// <summary>Why meetings are unavailable or unreadable, if they are.</summary>
    public string? Problem { get; }

    /// <summary>The selected meeting, as last loaded.</summary>
    public MeetingRecord? Selected { get; private set; }

    /// <summary>Titles in the list. Exposed for headless tests.</summary>
    public IReadOnlyList<string> ListedTitles => [.. _shown.Select(s => s.Title)];

    /// <summary>The transcript lines shown. Exposed for headless tests.</summary>
    public IReadOnlyList<string> ShownTranscript =>
        Selected is null ? [] : [.. Selected.Lines().Select(l => l.Rendered)];

    /// <summary>Runs the search now. Exposed for headless tests.</summary>
    public async Task SearchAsync()
    {
        if (_store is null) return;
        var generation = ++_searchGeneration;
        var query = _search.Text ?? string.Empty;
        var store = _store;
        var results = await Task.Run(() => store.Search(query)).ConfigureAwait(true);

        // A later search has started meanwhile: its results win.
        if (generation == _searchGeneration) Show(results);
    }

    /// <summary>Selects a meeting. Exposed for headless tests.</summary>
    public void Select(Guid id)
    {
        Selected = _store?.Load(id);
        ShowDetail();
        Highlight();
    }

    /// <summary>Renames a speaker everywhere in the selected meeting. Exposed for headless tests.</summary>
    public void Rename(string speakerId, string name)
    {
        if (_store is null || Selected is null) return;
        Selected = _store.RenameSpeaker(Selected.Id, speakerId, name) ?? Selected;
        ShowDetail();
    }

    /// <summary>The selected meeting as Markdown, in the user's time zone.</summary>
    public string? SelectedMarkdown => Selected?.Markdown(TimeZoneInfo.Local);

    private void Show(IReadOnlyList<MeetingSummary> summaries)
    {
        _shown = summaries;
        _list.Children.Clear();
        var total = _store?.Summaries.Count ?? 0;
        _count.Text = string.Create(CultureInfo.InvariantCulture, $"{total} MEETING{(total == 1 ? "" : "S")}");
        _deleteAll.IsVisible = total > 0;

        if (Problem is not null && total == 0)
        {
            _list.Children.Add(Panels.EmptyState("UNAVAILABLE", Problem));
        }
        else if (summaries.Count == 0)
        {
            _list.Children.Add(Panels.EmptyState(
                total == 0 ? "NO MEETINGS" : "NO MATCHES",
                total == 0 ? "Calls you take notes of appear here." : "Try a different search."));
        }

        foreach (var summary in summaries) _list.Children.Add(Row(summary));

        if (Selected is not null && summaries.All(s => s.Id != Selected.Id)) Selected = null;
        if (Selected is null && summaries.Count > 0) Select(summaries[0].Id);
        else ShowDetail();
        Highlight();
    }

    private Button Row(MeetingSummary summary)
    {
        var row = new Button
        {
            Tag = summary.Id,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(Tokens.Border.Hairline),
            CornerRadius = new CornerRadius(Tokens.Radius.Control),
            Padding = new Thickness(Tokens.Space.Snug),
            Content = new StackPanel
            {
                Spacing = Tokens.Space.Hair,
                Children =
                {
                    Body(summary.Title.Length == 0 ? "Untitled meeting" : summary.Title, Tokens.Fonts.Body, 1),
                    Body(Facts(summary.StartedAt, summary.Duration), Tokens.Fonts.Caption, 0.55),
                },
            },
        };
        row.Click += (_, _) => Select(summary.Id);
        return row;
    }

    private void Highlight()
    {
        foreach (var row in _list.Children.OfType<Button>())
        {
            var selected = row.Tag is Guid id && id == Selected?.Id;
            row.BorderBrush = new SolidColorBrush(Tokens.Colors.InkOnDeck, selected ? 0.5 : 0);
        }
    }

    private void ShowDetail()
    {
        _detail.Children.Clear();
        if (Selected is not { } meeting) return;

        var copy = Panels.DeckButton("COPY MARKDOWN");
        copy.Click += (_, _) => _ = CopyAsync(meeting.Markdown(TimeZoneInfo.Local), copy);
        var export = Panels.DeckButton("EXPORT…");
        export.Click += (_, _) => _ = ExportAsync(meeting);
        var delete = Panels.DeckButton("DELETE");
        delete.Click += (_, _) =>
        {
            if (delete.Content as string != "CONFIRM DELETE")
            {
                delete.Content = "CONFIRM DELETE";
                return;
            }

            _store?.Delete(meeting.Id);
            Selected = null;
        };

        _detail.Children.Add(Body(meeting.Title.Length == 0 ? "Untitled meeting" : meeting.Title, Tokens.Fonts.Title, 1));
        _detail.Children.Add(Body(
            Facts(meeting.StartedAt, meeting.Duration) + " · " + string.Join(", ", meeting.ParticipantNames()),
            Tokens.Fonts.Label, 0.6));
        _detail.Children.Add(new WrapPanel
        {
            ItemSpacing = Tokens.Space.Snug,
            LineSpacing = Tokens.Space.Tight,
            Children = { copy, export, delete },
        });

        _detail.Children.Add(Section("NOTES", Notes(meeting)));
        if (meeting.UserNotes.Trim().Length > 0) _detail.Children.Add(Section("MY NOTES", Body(meeting.UserNotes, Tokens.Fonts.Body, 0.9)));
        _detail.Children.Add(Section("SPEAKERS", Speakers(meeting)));
        _detail.Children.Add(Section("TRANSCRIPT", Transcript(meeting)));
    }

    private static Control Notes(MeetingRecord meeting)
    {
        if (meeting.Notes is not { } notes)
        {
            return Body("No notes. Windows has no notes model yet, so none were written: nothing is invented. "
                        + "The transcript below is complete.", Tokens.Fonts.Label, 0.6);
        }

        var panel = new StackPanel { Spacing = Tokens.Space.Snug };
        if (notes.Recap.Length > 0) panel.Children.Add(Body(notes.Recap, Tokens.Fonts.Body, 0.9));
        foreach (var step in notes.NextSteps)
        {
            panel.Children.Add(Body("☐ " + step.Text + (step.Owner is { } owner ? " — " + owner : "") + (step.Due is { } due ? $" ({due})" : ""),
                Tokens.Fonts.Body, 0.9));
        }

        foreach (var decision in notes.Decisions) panel.Children.Add(Body("Decided: " + decision, Tokens.Fonts.Body, 0.9));
        foreach (var question in notes.OpenQuestions) panel.Children.Add(Body("Open: " + question, Tokens.Fonts.Body, 0.9));
        return panel;
    }

    private StackPanel Speakers(MeetingRecord meeting)
    {
        var panel = new StackPanel { Spacing = Tokens.Space.Tight };
        foreach (var speaker in meeting.Speakers)
        {
            var name = Body(speaker.DisplayName, Tokens.Fonts.Body, 0.95);
            var source = Body(SourceText(speaker), Tokens.Fonts.Caption, 0.5);
            var field = new TextBox
            {
                Text = speaker.Name ?? string.Empty,
                Watermark = speaker.DisplayName,
                Width = 200,
                IsVisible = false,
                FontFamily = Tokens.Fonts.Grotesque,
                FontSize = Tokens.Fonts.Body,
            };
            var rename = Panels.DeckButton("RENAME");
            rename.Click += (_, _) =>
            {
                if (!field.IsVisible)
                {
                    field.IsVisible = true;
                    name.IsVisible = false;
                    rename.Content = "SAVE";
                    field.Focus();
                    return;
                }

                Rename(speaker.Id, field.Text ?? string.Empty);
            };

            panel.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Tokens.Space.Snug,
                Children = { name, field, source, rename },
            });
        }

        return panel;
    }

    private static string SourceText(Speaker speaker) => speaker.NameSource switch
    {
        NameSource.User => "named by you",
        NameSource.MeetingWindow => "from the meeting window",
        NameSource.Calendar => "from the calendar",
        NameSource.VoicePrint => "recognised voice",
        _ => speaker.IsMe ? "this computer's microphone" : speaker.Id == Speaker.OthersId ? "not separated" : "voice in the call",
    };

    private static StackPanel Transcript(MeetingRecord meeting)
    {
        var panel = new StackPanel { Spacing = Tokens.Space.Snug };
        var lines = meeting.Lines();
        if (lines.Count == 0) panel.Children.Add(Body("Nothing was transcribed.", Tokens.Fonts.Label, 0.6));
        foreach (var line in lines)
        {
            panel.Children.Add(new StackPanel
            {
                Spacing = Tokens.Space.Hair,
                Children =
                {
                    new TextBlock
                    {
                        Text = $"{MeetingRecord.Clock(line.Start)}  {line.Speaker.ToUpperInvariant()}",
                        FontFamily = Tokens.Fonts.Mono,
                        FontSize = Tokens.Fonts.Caption,
                        Foreground = new SolidColorBrush(Tokens.Colors.InkOnDeck, 0.55),
                    },
                    Body(line.Text, Tokens.Fonts.Body, 0.95),
                },
            });
        }

        return panel;
    }

    private void DeleteAll()
    {
        if (!_confirmingDeleteAll)
        {
            _confirmingDeleteAll = true;
            _deleteAll.Content = "CONFIRM: DELETE EVERY MEETING";
            return;
        }

        _confirmingDeleteAll = false;
        _deleteAll.Content = "DELETE ALL";
        Selected = null;
        _store?.DeleteAll();
    }

    private async Task CopyAsync(string text, Button key)
    {
        var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
        if (clipboard is null) return;
        await clipboard.SetDataAsync(App.PrivateText(text, ClipboardPrivacy.ForUserCopy())).ConfigureAwait(true);
        var label = key.Content;
        key.Content = "COPIED";
        await Task.Delay(TimeSpan.FromSeconds(1.4)).ConfigureAwait(true);
        key.Content = label;
    }

    private async Task ExportAsync(MeetingRecord meeting)
    {
        var storage = TopLevel.GetTopLevel(this)?.StorageProvider;
        if (storage is null || !storage.CanSave) return;
        var file = await storage.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Export meeting",
            SuggestedFileName = meeting.MarkdownFilename(TimeZoneInfo.Local),
            DefaultExtension = "md",
            FileTypeChoices = [new FilePickerFileType("Markdown") { Patterns = ["*.md"] }],
        }).ConfigureAwait(true);
        if (file is null) return;

        await using var stream = await file.OpenWriteAsync().ConfigureAwait(true);
        await using var writer = new StreamWriter(stream, AtomicFile.Utf8);
        await writer.WriteAsync(meeting.Markdown(TimeZoneInfo.Local)).ConfigureAwait(true);
    }

    private static string Facts(DateTimeOffset startedAt, TimeSpan duration) =>
        startedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture) + " · " + DurationText.Format(duration.TotalSeconds);

    private static StackPanel Section(string label, Control content) => new()
    {
        Spacing = Tokens.Space.Snug,
        Children = { new Silkscreen { Text = label, Foreground = new SolidColorBrush(Tokens.Colors.InkOnDeck, 0.55) }, content },
    };

    private static TextBlock Body(string text, double size, double opacity) => new()
    {
        Text = text,
        FontFamily = Tokens.Fonts.Grotesque,
        FontSize = size,
        Foreground = new SolidColorBrush(Tokens.Colors.InkOnDeck, opacity),
        TextWrapping = TextWrapping.Wrap,
        VerticalAlignment = VerticalAlignment.Center,
    };
}
