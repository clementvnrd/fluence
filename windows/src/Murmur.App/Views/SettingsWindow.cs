using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Murmur.App.Controls;
using Murmur.App.Design;
using Murmur.Core;
using Murmur.Speech;

namespace Murmur.App.Views;

/// <summary>Settings: the hotkey and the model.</summary>
public sealed class SettingsWindow : Window
{
    /// <summary>
    /// The keys offered, in recommendation order.
    /// </summary>
    /// <remarks>
    /// Right Alt is included but listed last and carries a warning: on German, Polish, UK,
    /// Nordic and most Latin-American layouts it is AltGr, and binding push-to-talk there
    /// breaks typing <c>@</c>, <c>€</c>, <c>\</c> and <c>|</c>.
    /// </remarks>
    private static readonly (int Key, string Label, string? Warning)[] Keys =
    [
        (0xA3, "RIGHT CTRL", null),
        (0xA1, "RIGHT SHIFT", null),
        (0x14, "CAPS LOCK", null),
        (0x7C, "F13", null),
        (0xA5, "RIGHT ALT", "Right Alt is AltGr on many European layouts — binding it here "
                          + "will interfere with typing @, €, \\ and |."),
    ];

    /// <summary>History retention choices, shortest first.</summary>
    private static readonly (HistoryRetention Retention, string Label)[] Retentions =
    [
        (HistoryRetention.Never, "NEVER"),
        (HistoryRetention.OneDay, "1 DAY"),
        (HistoryRetention.ThirtyDays, "30 DAYS"),
        (HistoryRetention.Forever, "FOREVER"),
    ];

    private readonly AppSettings _settings;
    private readonly TranscriptStore? _history;
    private readonly StackPanel _keyRow;
    private readonly StackPanel _retentionRow;
    private readonly TextBlock _keyWarning;

    /// <summary>Builds the settings window.</summary>
    /// <param name="settings">The preferences being edited.</param>
    /// <param name="history">The history, to report whether it is sealed on disk.</param>
    public SettingsWindow(AppSettings settings, TranscriptStore? history = null)
    {
        _settings = settings;
        _history = history;

        Title = AppPaths.ProductName + " Settings";
        Width = 540;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        Background = Tokens.Brushes.Chassis;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _keyRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Tokens.Space.Snug,
        };

        _keyWarning = new TextBlock
        {
            FontFamily = Tokens.Fonts.Grotesque,
            FontSize = Tokens.Fonts.Label,
            Foreground = new SolidColorBrush(Tokens.Colors.MeterAmber),
            TextWrapping = TextWrapping.Wrap,
            IsVisible = false,
        };

        foreach (var (key, label, warning) in Keys)
        {
            var button = new TransportKey { Content = label, EngagedColor = Tokens.Colors.Ink };
            button.Click += (_, _) => SelectKey(key, warning);
            _keyRow.Children.Add(button);
        }

        _retentionRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Tokens.Space.Snug,
        };

        foreach (var (retention, label) in Retentions)
        {
            var button = new TransportKey { Content = label, EngagedColor = Tokens.Colors.Ink };
            button.Click += (_, _) => SelectRetention(retention);
            _retentionRow.Children.Add(button);
        }

        Content = BuildContent();
        SelectKey(_settings.Data.PushToTalkKey, WarningFor(_settings.Data.PushToTalkKey));
        SelectRetention(_settings.Data.HistoryRetention);
    }

    /// <summary>The retention currently engaged. Exposed for headless tests.</summary>
    public HistoryRetention SelectedRetention => _settings.Data.HistoryRetention;

    /// <summary>Engages a retention button and saves. Exposed for headless tests.</summary>
    public void SelectRetention(HistoryRetention retention)
    {
        for (var i = 0; i < Retentions.Length; i++)
        {
            ((TransportKey)_retentionRow.Children[i]).IsEngaged = Retentions[i].Retention == retention;
        }

        if (_settings.Data.HistoryRetention != retention)
        {
            Save(_settings.Data with { HistoryRetention = retention });
        }
    }

    private static string? WarningFor(int key) =>
        Keys.FirstOrDefault(k => k.Key == key).Warning;

    private StackPanel BuildContent() => new StackPanel
    {
        Margin = new Thickness(Tokens.Space.Panel),
        Spacing = Tokens.Space.Wide,
        Children =
        {
            Section("PUSH TO TALK", new StackPanel
            {
                Spacing = Tokens.Space.Snug,
                Children =
                {
                    _keyRow,
                    _keyWarning,
                    Note("Hold this key anywhere to dictate. The key is passed through to the "
                       + "focused app rather than swallowed, so it never gets stuck down."),
                },
            }),

            Section("MODEL", BuildModelSection()),

            Section("BEHAVIOUR", new StackPanel
            {
                Spacing = Tokens.Space.Snug,
                Children =
                {
                    Toggle("Type transcripts into the focused app", _settings.Data.InjectText,
                        v => Save(_settings.Data with { InjectText = v })),
                },
            }),

            Section("HISTORY", new StackPanel
            {
                Spacing = Tokens.Space.Snug,
                Children =
                {
                    _retentionRow,
                    Note(HistoryNote(_history)),
                },
            }),
        },
    };

    private static string HistoryNote(TranscriptStore? history)
    {
        if (history?.Problem is { } problem) return problem;

        return "Each transcript is encrypted on disk (AES-256-GCM) with a key only your Windows "
             + "account can unlock. Older entries are deleted at startup and after every "
             + "dictation. Never deletes the existing history now.";
    }

    private static StackPanel BuildModelSection()
    {
        var located = ParakeetTranscriber.Locate();
        var found = located is not null;

        var status = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Tokens.Space.Snug,
            Children =
            {
                new Lamp
                {
                    IsLit = found,
                    LampColor = found ? Tokens.Colors.MeterGreen : Tokens.Colors.MeterAmber,
                    VerticalAlignment = VerticalAlignment.Center,
                },
                new TextBlock
                {
                    Text = found ? "Parakeet ready" : "Model not installed",
                    FontFamily = Tokens.Fonts.Grotesque,
                    FontSize = Tokens.Fonts.Body,
                    Foreground = Tokens.Brushes.Ink,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            },
        };

        var detail = found
            // Showing the resolved path matters: "model not found" is unactionable without
            // knowing which directory was actually checked.
            ? Note($"Loaded from {located}")
            : Note("Windows has no built-in speech engine equivalent to Apple's, so Fluence "
                 + "cannot transcribe until the Parakeet model is downloaded (~661 MB). "
                 + "See docs/PARAKEET-WINDOWS.md. Expected in:\n"
                 + string.Join("\n", ParakeetTranscriber.DefaultSearchPaths()));

        return new StackPanel { Spacing = Tokens.Space.Snug, Children = { status, detail } };
    }

    private void SelectKey(int key, string? warning)
    {
        for (var i = 0; i < Keys.Length; i++)
        {
            ((TransportKey)_keyRow.Children[i]).IsEngaged = Keys[i].Key == key;
        }

        _keyWarning.Text = warning ?? string.Empty;
        _keyWarning.IsVisible = warning is not null;

        if (_settings.Data.PushToTalkKey != key) Save(_settings.Data with { PushToTalkKey = key });
    }

    private void Save(SettingsData data) => _settings.Update(data);

    private static BrushedPanel Section(string label, Control content) => new BrushedPanel
    {
        Child = new StackPanel
        {
            Margin = new Thickness(Tokens.Space.Roomy),
            Spacing = Tokens.Space.Base,
            Children = { new Silkscreen { Text = label, IsLarge = true }, content },
        },
    };

    private static TextBlock Note(string text) => new()
    {
        Text = text,
        FontFamily = Tokens.Fonts.Grotesque,
        FontSize = Tokens.Fonts.Label,
        Foreground = new SolidColorBrush(Tokens.Colors.InkSecondary),
        TextWrapping = TextWrapping.Wrap,
    };

    private static CheckBox Toggle(string label, bool value, Action<bool> onChange)
    {
        var box = new CheckBox
        {
            IsChecked = value,
            Content = new TextBlock
            {
                Text = label,
                FontFamily = Tokens.Fonts.Grotesque,
                FontSize = Tokens.Fonts.Body,
                Foreground = Tokens.Brushes.Ink,
            },
        };

        box.IsCheckedChanged += (_, _) => onChange(box.IsChecked ?? false);
        return box;
    }
}
