using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
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
    private readonly TranscriberHost? _model;
    private readonly Lamp _modelLamp = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _modelHeadline = new()
    {
        FontFamily = Tokens.Fonts.Grotesque,
        FontSize = Tokens.Fonts.Body,
        Foreground = Tokens.Brushes.Ink,
        VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly TextBlock _modelDetail = Note(string.Empty);
    private readonly TransportKey _modelRetry = new() { Content = "TRY AGAIN", EngagedColor = Tokens.Colors.Ink };
    private readonly StackPanel _keyRow;
    private readonly StackPanel _retentionRow;
    private readonly TextBlock _keyWarning;

    /// <summary>Builds the settings window.</summary>
    /// <param name="settings">The preferences being edited.</param>
    /// <param name="history">The history, to report whether it is sealed on disk.</param>
    /// <param name="model">The speech model, whose real load state is shown.</param>
    public SettingsWindow(AppSettings settings, TranscriptStore? history = null, TranscriberHost? model = null)
    {
        _settings = settings;
        _history = history;
        _model = model;

        // The model loads in the background; follow it live rather than showing a snapshot.
        if (_model is not null)
        {
            EventHandler onChange = (_, _) => Dispatcher.UIThread.Post(UpdateModelStatus);
            _model.StateChanged += onChange;
            Closed += (_, _) => _model.StateChanged -= onChange;
        }

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
                    Note("Hold this key anywhere to dictate; a tap shorter than a quarter second, "
                       + "or holding it with another key (a shortcut such as Ctrl+C), is ignored. "
                       + "The key is passed through to the focused app rather than swallowed, so "
                       + "it never gets stuck down — except Caps Lock, which is swallowed so "
                       + "dictating does not toggle it. Changes apply after restarting Fluence."),
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
                    Note("Off: dictations go to the history only, nothing is typed."),
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

    private StackPanel BuildModelSection()
    {
        _modelRetry.Click += (_, _) => _ = _model?.LoadAsync(CancellationToken.None).AsTask();

        var status = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Tokens.Space.Snug,
            Children = { _modelLamp, _modelHeadline },
        };

        UpdateModelStatus();
        return new StackPanel { Spacing = Tokens.Space.Snug, Children = { status, _modelDetail, _modelRetry } };
    }

    /// <summary>The model status currently shown. Exposed for headless tests.</summary>
    public ModelStatus? ShownModelStatus { get; private set; }

    private void UpdateModelStatus()
    {
        var searched = ParakeetTranscriber.SearchPaths(_settings.Data.ModelDirectory, AppPaths.ModelsDirectory);
        var status = _model is null
            ? ModelStatus.Describe(ModelState.NotInstalled, null, null, searched)
            : ModelStatus.Describe(_model.State, _model.Detail, _model.Location, searched);

        ShownModelStatus = status;
        _modelLamp.IsLit = status.IsReady || _model?.State == ModelState.Loading;
        _modelLamp.LampColor = status.IsReady ? Tokens.Colors.MeterGreen : Tokens.Colors.MeterAmber;
        _modelHeadline.Text = status.Headline;
        _modelDetail.Text = status.Detail;
        _modelRetry.IsVisible = _model?.State == ModelState.Failed;
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
