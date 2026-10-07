using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Murmur.App.Controls;
using Murmur.App.Design;
using Murmur.Core;

namespace Murmur.App.Views;

/// <summary>
/// The main window — the front panel of the unit.
/// </summary>
/// <remarks>
/// <para>
/// Laid out the way a deck is: transport and meter across the top on the panel itself, then a
/// recessed well below holding whichever section is selected.
/// </para>
/// <para>
/// Built in code rather than XAML, deliberately. Every value comes from <see cref="Tokens"/>,
/// and XAML makes it far too easy to type a literal <c>Margin="12,8"</c> that silently escapes
/// the design system. In C# a stray number is visible in review.
/// </para>
/// </remarks>
public sealed class MainWindow : Window
{
    private readonly Composition? _composition;
    private readonly TransportKey _recordKey;
    private readonly Lamp _recordLamp;
    private readonly VuMeter _meter;
    private readonly TextBlock _counter;
    private readonly ContentControl _sectionHost;
    private readonly TransportKey _transcriptionsKey;
    private readonly TransportKey _dictionaryKey;
    private readonly TransportKey _meetingsKey;
    private readonly TransportKey _takeNotesKey;
    private readonly DispatcherTimer _counterTimer;
    private readonly BrushedPanel _banner;
    private readonly TextBlock _bannerText = new()
    {
        FontFamily = Tokens.Fonts.Grotesque,
        FontSize = Tokens.Fonts.Label,
        Foreground = Tokens.Brushes.Ink,
        TextWrapping = TextWrapping.Wrap,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private Control? _transcriptionsView;
    private Control? _dictionaryView;
    private MeetingsView? _meetingsView;
    private DateTimeOffset? _startedAt;

    /// <summary>Builds a window with no engine behind it. Used by headless tests.</summary>
    public MainWindow() : this(null) { }

    /// <summary>Builds the window over <paramref name="composition"/>.</summary>
    public MainWindow(Composition? composition)
    {
        _composition = composition;

        Title = AppPaths.ProductName;
        MinWidth = 720;
        MinHeight = 520;
        Width = 880;
        Height = 640;
        Background = Tokens.Brushes.Chassis;

        _recordKey = new TransportKey { Content = "RECORD" };
        _recordKey.Click += (_, _) => ToggleRecording();

        _recordLamp = new Lamp { LampColor = Tokens.Colors.Record };
        _meter = new VuMeter { Width = 168, Height = 54 };

        _counter = new TextBlock
        {
            Text = "00:00",
            FontFamily = Tokens.Fonts.Mono,
            FontSize = Tokens.Fonts.CounterLarge,
            Foreground = Tokens.Brushes.InkOnDeck,
        };

        _transcriptionsKey = new TransportKey { Content = "TRANSCRIPTIONS", IsEngaged = true };
        _dictionaryKey = new TransportKey { Content = "DICTIONARY" };
        _meetingsKey = new TransportKey { Content = "MEETINGS" };
        _transcriptionsKey.Click += (_, _) => ShowSection(Section.Transcriptions);
        _dictionaryKey.Click += (_, _) => ShowSection(Section.Dictionary);
        _meetingsKey.Click += (_, _) => ShowSection(Section.Meetings);

        // The Notetaker's manual start. Detection offers it by itself; this is for calls it
        // does not know, and it is never a silent start: the recording panel appears at once.
        _takeNotesKey = new TransportKey { Content = "TAKE NOTES", EngagedColor = Tokens.Colors.Ink };
        _takeNotesKey.Click += (_, _) => ToggleMeetingNotes();

        _sectionHost = new ContentControl();
        _banner = BuildBanner();

        // The meter and counter are polled rather than pushed. The engine raises Changed on
        // a background thread at buffer rate, and marshalling every one of those to the UI
        // thread would be far more traffic than a display refresh needs.
        _counterTimer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromMilliseconds(100),
        };
        _counterTimer.Tick += (_, _) => SyncFromEngine();
        _counterTimer.Start();

        Content = BuildLayout();
        ShowSection(Section.Transcriptions);

        if (_composition?.Engine is not null) _composition.Engine.Start();
    }

    private DockPanel BuildLayout()
    {
        var root = new DockPanel { Margin = new Thickness(Tokens.Space.Roomy) };

        root.Children.Add(Panels.Docked(BuildTransportPanel(), Dock.Top));
        root.Children.Add(Panels.Docked(BuildSectionKeys(), Dock.Top));

        root.Children.Add(Panels.Docked(_banner, Dock.Top));

        root.Children.Add(BuildWell(_sectionHost));
        return root;
    }

    /// <summary>Record/stop, the record lamp, the level meter and the tape counter.</summary>
    private BrushedPanel BuildTransportPanel()
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Tokens.Space.Wide,
            Margin = new Thickness(Tokens.Space.Roomy),
        };

        row.Children.Add(Panels.Labelled("TRANSPORT", new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Tokens.Space.Snug,
            Children =
            {
                _recordKey,
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = Tokens.Space.Tight,
                    VerticalAlignment = VerticalAlignment.Center,
                    Children = { _recordLamp, new Silkscreen { Text = "REC" } },
                },
            },
        }));

        row.Children.Add(Panels.Labelled("LEVEL", _meter));
        row.Children.Add(Panels.Labelled("COUNTER", Deck(_counter)));

        var settings = new TransportKey { Content = "SETTINGS" };
        settings.Click += (_, _) => ShowSettings();

        row.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Tokens.Space.Base,
            VerticalAlignment = VerticalAlignment.Bottom,
            Children = { _takeNotesKey, settings, new Vents { Count = 8, VerticalAlignment = VerticalAlignment.Center } },
        });

        return new BrushedPanel { Child = row, Margin = new Thickness(0, 0, 0, Tokens.Space.Base) };
    }

    private StackPanel BuildSectionKeys() => new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = Tokens.Space.Snug,
        Margin = new Thickness(0, 0, 0, Tokens.Space.Base),
        Children = { _transcriptionsKey, _dictionaryKey, _meetingsKey },
    };

    /// <summary>
    /// A standing notice for anything that stops dictation working: no model, a model that
    /// failed to load, or the last dictation's error.
    /// </summary>
    /// <remarks>
    /// Unlike macOS, Windows has no built-in engine to fall back on, so a missing or broken
    /// model means the app does nothing at all. That has to be visible on the front panel
    /// rather than buried in Settings — and so does a dictation that failed, which used to
    /// vanish without a word.
    /// </remarks>
    private BrushedPanel BuildBanner() => new()
    {
        Margin = new Thickness(0, 0, 0, Tokens.Space.Base),
        IsVisible = false,
        Child = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Tokens.Space.Base,
            Margin = new Thickness(Tokens.Space.Base),
            Children =
            {
                new Lamp
                {
                    IsLit = true,
                    LampColor = Tokens.Colors.MeterAmber,
                    VerticalAlignment = VerticalAlignment.Center,
                },
                _bannerText,
            },
        },
    };

    /// <summary>The banner's message, or null when hidden. Exposed for headless tests.</summary>
    public string? BannerMessage => _banner.IsVisible ? _bannerText.Text : null;

    private void UpdateBanner()
    {
        var message = Describe(_composition);
        _banner.IsVisible = message is not null;
        if (message is not null && _bannerText.Text != message) _bannerText.Text = message;
    }

    /// <summary>What the banner should say, or null for nothing.</summary>
    internal static string? Describe(Composition? composition)
    {
        if (composition is null) return null;

        // The last dictation's failure comes first: it is what the user just experienced.
        if (composition.Engine?.LastError is { } error) return error;

        var model = composition.Model;
        var status = ModelStatus.Describe(model.State, model.Detail, model.Location, []);
        if (!status.NeedsAttention) return null;

        return model.State == ModelState.Failed
            ? $"Speech model failed to load — {model.Detail} See Settings."
            : "Speech model not installed — Fluence cannot transcribe yet. See Settings, or docs/PARAKEET-WINDOWS.md.";
    }

    /// <summary>A recessed well cut into the panel — content sits inside it.</summary>
    private static Border BuildWell(Control content) => new()
    {
        Background = Tokens.Brushes.Well,
        CornerRadius = new CornerRadius(Tokens.Radius.Panel),
        BorderBrush = new SolidColorBrush(Tokens.Colors.Seam, 0.55),
        BorderThickness = new Thickness(Tokens.Border.Hairline),
        Padding = new Thickness(Tokens.Space.Hair),
        Child = content,
    };

    /// <summary>The dark readout window of a tape deck.</summary>
    private static Border Deck(Control content) => new()
    {
        Background = Tokens.Brushes.Deck,
        CornerRadius = new CornerRadius(Tokens.Radius.Panel),
        BorderBrush = new SolidColorBrush(Tokens.Colors.Seam),
        BorderThickness = new Thickness(Tokens.Border.Hairline),
        Padding = new Thickness(Tokens.Space.Base, Tokens.Space.Snug),
        Child = content,
    };

    private enum Section
    {
        Transcriptions,
        Dictionary,
        Meetings,
    }

    private void ShowSection(Section section)
    {
        _transcriptionsKey.IsEngaged = section == Section.Transcriptions;
        _dictionaryKey.IsEngaged = section == Section.Dictionary;
        _meetingsKey.IsEngaged = section == Section.Meetings;

        if (_composition is null)
        {
            _sectionHost.Content = section switch
            {
                Section.Transcriptions => Panels.EmptyState("NO RECORDINGS", "Press Record to start."),
                Section.Dictionary => Panels.EmptyState("DICTIONARY EMPTY", "Add words it keeps getting wrong."),
                _ => Panels.EmptyState("NO MEETINGS", "Calls you take notes of appear here."),
            };
            return;
        }

        // Built once and reused: rebuilding would drop the user's search text every time
        // they switched tabs.
        _sectionHost.Content = section switch
        {
            Section.Transcriptions => _transcriptionsView ??= new TranscriptionsView(_composition.Transcripts),
            Section.Dictionary => _dictionaryView ??= new DictionaryView(_composition.Dictionary),
            _ => _meetingsView ??= new MeetingsView(_composition.Meetings.Store, _composition.Meetings.Problem),
        };
    }

    /// <summary>Shows the Meetings section. Used by the tray and after a meeting is saved.</summary>
    public void ShowMeetings() => ShowSection(Section.Meetings);

    /// <summary>Starts taking notes, or stops. Exposed for the tray.</summary>
    public void ToggleMeetingNotes()
    {
        if (_composition?.Meetings.Controller is not { } meetings) return;
        _ = meetings.IsRecording ? meetings.StopAsync(Meeting.StopReason.User) : meetings.TakeNotesAsync();
    }

    private void ShowSettings()
    {
        if (_composition is null) return;
        _ = new SettingsWindow(_composition.Settings, _composition.Transcripts, _composition.Model, _composition.Meetings.Store)
            .ShowDialog(this);
    }

    /// <summary>Pulls state from the engine onto the panel.</summary>
    private void SyncFromEngine()
    {
        UpdateBanner();

        var meetings = _composition?.Meetings.Controller;
        _takeNotesKey.IsEnabled = meetings is not null;
        _takeNotesKey.IsEngaged = meetings?.IsRecording ?? false;
        _takeNotesKey.Content = meetings?.IsRecording == true ? "STOP NOTES" : "TAKE NOTES";

        var engine = _composition?.Engine;
        if (engine is null)
        {
            if (_startedAt is not null) UpdateCounter();
            return;
        }

        var recording = engine.State is DictationState.Recording or DictationState.Transcribing;

        _meter.Level = engine.Level;
        _meter.IsActive = recording;
        _recordLamp.IsLit = engine.State == DictationState.Recording;
        _recordKey.IsEngaged = recording;
        _recordKey.Content = recording ? "STOP" : "RECORD";

        if (recording && _startedAt is null) _startedAt = DateTimeOffset.Now;
        else if (!recording) _startedAt = null;

        UpdateCounter();
    }

    private void UpdateCounter()
    {
        var elapsed = _startedAt is null ? TimeSpan.Zero : DateTimeOffset.Now - _startedAt.Value;
        _counter.Text = string.Create(
            CultureInfo.InvariantCulture,
            $"{(int)elapsed.TotalMinutes:00}:{elapsed.Seconds:00}");
    }

    /// <summary>Toggles the transport. Exposed for headless tests.</summary>
    public void ToggleRecording()
    {
        // With no engine — a headless test, or a machine with no platform layer — the panel
        // still toggles so the visual state can be exercised.
        if (_composition?.Engine is null)
        {
            IsRecording = !IsRecording;
            _recordKey.Content = IsRecording ? "STOP" : "RECORD";
            _recordKey.IsEngaged = IsRecording;
            _recordLamp.IsLit = IsRecording;
            _meter.IsActive = IsRecording;
            _startedAt = IsRecording ? DateTimeOffset.Now : null;
            return;
        }

        // The button is a convenience; the hotkey is the real trigger. Both funnel through
        // the same engine so there is only ever one state machine.
        _composition.Engine.TogglePushToTalk();
        SyncFromEngine();
    }

    /// <summary>Whether the transport is engaged. Exposed for headless tests.</summary>
    public bool IsRecording { get; private set; }

    /// <summary>The record lamp. Exposed for headless tests.</summary>
    public Lamp RecordLamp => _recordLamp;

    /// <summary>The level meter. Exposed for headless tests.</summary>
    public VuMeter Meter => _meter;

    /// <inheritdoc />
    /// <inheritdoc />
    /// <remarks>
    /// The X hides to the tray; it never truly closes. An Avalonia window cannot be
    /// re-shown once closed — observed live: close the window, click "Show" in the tray,
    /// and the whole process died with "Cannot re-show a closed window". Real closing
    /// happens only on application shutdown, which arrives with a different close reason
    /// and is let through.
    /// </remarks>
    protected override void OnClosing(WindowClosingEventArgs e)
    {
        if (e.CloseReason == WindowCloseReason.WindowClosing)
        {
            e.Cancel = true;
            Hide();
        }

        base.OnClosing(e);
    }

    /// <inheritdoc />
    protected override void OnClosed(EventArgs e)
    {
        _counterTimer.Stop();
        base.OnClosed(e);
    }
}
