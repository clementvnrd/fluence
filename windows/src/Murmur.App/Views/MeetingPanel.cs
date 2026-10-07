using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Murmur.App.Controls;
using Murmur.App.Design;
using Murmur.Core;
using Murmur.Core.Meetings;
using Murmur.Meeting;

namespace Murmur.App.Views;

/// <summary>
/// The Notetaker's small on-screen panel: the "call detected" card with its countdown, then
/// the recording strip (lit record lamp, counter, Stop, Keep audio), then "processing".
/// </summary>
/// <remarks>
/// <para>
/// <b>Never records silently.</b> The card says what will happen and counts down visibly;
/// while recording, the lamp is lit and the strip stays on screen. The lamp is the only red,
/// and only while recording: the card and the processing state leave it dark.
/// </para>
/// <para>
/// The consent keys copy the same notice as macOS (<see cref="ConsentNotice"/>), in French or
/// English, for the meeting chat.
/// </para>
/// </remarks>
public sealed class MeetingPanel : UserControl
{
    private readonly MeetingController _controller;
    private readonly Lamp _lamp = new() { LampColor = Tokens.Colors.Record, VerticalAlignment = VerticalAlignment.Center };
    private readonly Silkscreen _headline = new() { IsLarge = true, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _detail = Text(Tokens.Fonts.Label, 0.75);
    private readonly TextBlock _counter = new()
    {
        FontFamily = Tokens.Fonts.Mono,
        FontSize = Tokens.Fonts.Title,
        Foreground = Tokens.Brushes.InkOnDeck,
        VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly TransportKey _record = Key("RECORD");
    private readonly TransportKey _notNow = Key("NOT NOW");
    private readonly TransportKey _stop = Key("STOP");
    private readonly TransportKey _dismiss = Key("OK");
    private readonly TransportKey _consentFr = Key("CONSENT FR");
    private readonly TransportKey _consentEn = Key("CONSENT EN");
    private readonly CheckBox _keepAudio = new()
    {
        Content = Text(Tokens.Fonts.Label, 0.85, "Keep audio"),
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>Builds the panel over <paramref name="controller"/>.</summary>
    public MeetingPanel(MeetingController controller)
    {
        _controller = controller;
        _record.Click += (_, _) => _ = _controller.AcceptAsync();
        _notNow.Click += (_, _) => _controller.Dismiss();
        _stop.Click += (_, _) => _ = _controller.StopAsync(StopReason.User);
        _dismiss.Click += (_, _) => _controller.DismissProblem();
        _keepAudio.IsCheckedChanged += (_, _) => _controller.KeepAudio = _keepAudio.IsChecked ?? false;
        _consentFr.Click += (_, _) => _ = CopyConsentAsync(NotesLanguage.French, _consentFr);
        _consentEn.Click += (_, _) => _ = CopyConsentAsync(NotesLanguage.English, _consentEn);
        ToolTip.SetTip(_consentFr, ConsentNotice.Text(NotesLanguage.French));
        ToolTip.SetTip(_consentEn, ConsentNotice.Text(NotesLanguage.English));
        ToolTip.SetTip(_keepAudio, "Off: the encrypted recording is deleted once the transcript is ready.");

        Content = new Border
        {
            Background = Tokens.Brushes.Deck,
            CornerRadius = new CornerRadius(Tokens.Radius.Panel),
            BorderBrush = new SolidColorBrush(Tokens.Colors.Seam),
            BorderThickness = new Thickness(Tokens.Border.Hairline),
            Padding = new Thickness(Tokens.Space.Base),
            Child = new StackPanel
            {
                Spacing = Tokens.Space.Snug,
                Children =
                {
                    new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        Spacing = Tokens.Space.Snug,
                        Children = { _lamp, _headline, _counter },
                    },
                    _detail,
                    new WrapPanel
                    {
                        ItemSpacing = Tokens.Space.Snug,
                        LineSpacing = Tokens.Space.Tight,
                        Children = { _record, _notNow, _stop, _keepAudio, _consentFr, _consentEn, _dismiss },
                    },
                },
            },
        };

        Refresh();
    }

    /// <summary>Whether the panel has anything to show (the window hides otherwise).</summary>
    public bool HasContent => _controller.State != MeetingState.Idle;

    /// <summary>The record lamp. Exposed for headless tests.</summary>
    public Lamp RecordLamp => _lamp;

    /// <summary>The headline. Exposed for headless tests.</summary>
    public string? Headline => _headline.Text;

    /// <summary>The line under it. Exposed for headless tests.</summary>
    public string? Detail => _detail.Text;

    /// <summary>The keys visible now, by label. Exposed for headless tests.</summary>
    public IReadOnlyList<string> VisibleKeys =>
        [.. new[] { _record, _notNow, _stop, _dismiss, _consentFr, _consentEn }.Where(k => k.IsVisible).Select(k => k.Content as string ?? "")];

    /// <summary>Whether the Keep audio checkbox is shown. Exposed for headless tests.</summary>
    public bool ShowsKeepAudio => _keepAudio.IsVisible;

    /// <summary>Re-reads the controller. Call on the UI thread.</summary>
    public void Refresh()
    {
        var state = _controller.State;
        _lamp.IsLit = state == MeetingState.Recording;
        _lamp.IsVisible = state is MeetingState.Recording or MeetingState.Processing;
        _record.IsVisible = _notNow.IsVisible = state == MeetingState.Detected;
        _stop.IsVisible = _keepAudio.IsVisible = state == MeetingState.Recording;
        _consentFr.IsVisible = _consentEn.IsVisible = state is MeetingState.Detected or MeetingState.Recording;
        _dismiss.IsVisible = state == MeetingState.Failed;
        _counter.IsVisible = state == MeetingState.Recording;

        switch (state)
        {
            case MeetingState.Detected:
                var service = _controller.Detected?.Service ?? "A";
                _headline.Text = $"{service.ToUpperInvariant()} CALL DETECTED";
                _detail.Text = _controller.Countdown is { } seconds
                    ? string.Create(CultureInfo.InvariantCulture, $"Taking notes in {seconds} s — tell the others first. Not now to skip this call.")
                    : "Take notes of this call? Tell the others first.";
                break;
            case MeetingState.Recording:
                _headline.Text = "TAKING NOTES";
                _counter.Text = MeetingRecord.Clock(_controller.Elapsed);
                _detail.Text = _controller.Notice ?? "Transcribed on this computer. Nothing is sent over the Internet.";
                if ((_keepAudio.IsChecked ?? false) != _controller.KeepAudio) _keepAudio.IsChecked = _controller.KeepAudio;
                break;
            case MeetingState.Processing:
                _headline.Text = "PROCESSING";
                _detail.Text = "Separating the voices and saving the meeting.";
                break;
            case MeetingState.Failed:
                _headline.Text = "NOT RECORDING";
                _detail.Text = _controller.Problem;
                break;
            default:
                _headline.Text = string.Empty;
                _detail.Text = string.Empty;
                break;
        }
    }

    private async Task CopyConsentAsync(NotesLanguage language, TransportKey key)
    {
        var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
        if (clipboard is null) return;
        await clipboard.SetDataAsync(App.PrivateText(ConsentNotice.Text(language), ClipboardPrivacy.ForUserCopy())).ConfigureAwait(true);
        var label = key.Content;
        key.Content = "COPIED";
        await Task.Delay(TimeSpan.FromSeconds(1.4)).ConfigureAwait(true);
        key.Content = label;
    }

    private static TransportKey Key(string label) => new() { Content = label, EngagedColor = Tokens.Colors.Ink };

    private static TextBlock Text(double size, double opacity, string text = "") => new()
    {
        Text = text,
        FontFamily = Tokens.Fonts.Grotesque,
        FontSize = size,
        Foreground = new SolidColorBrush(Tokens.Colors.InkOnDeck, opacity),
        TextWrapping = TextWrapping.Wrap,
        MaxWidth = 420,
    };
}

/// <summary>
/// A small always-on-top window for <see cref="MeetingPanel"/>, near the bottom-right corner.
/// Shown whenever the Notetaker has something to say; never taking focus from the call.
/// </summary>
public sealed class MeetingPanelWindow : Window
{
    /// <summary>Builds the window over <paramref name="controller"/>.</summary>
    public MeetingPanelWindow(MeetingController controller)
    {
        Panel = new MeetingPanel(controller);
        Title = AppPaths.ProductName + " Notetaker";
        Topmost = true;
        ShowActivated = false;
        ShowInTaskbar = false;
        CanResize = false;
        SystemDecorations = SystemDecorations.BorderOnly;
        SizeToContent = SizeToContent.WidthAndHeight;
        Background = Tokens.Brushes.Chassis;
        Content = new Border { Padding = new Thickness(Tokens.Space.Hair), Child = Panel };
        controller.Changed += (_, _) => Dispatcher.UIThread.Post(Sync);
    }

    /// <summary>The panel. Exposed for headless tests.</summary>
    public MeetingPanel Panel { get; }

    /// <summary>Refreshes and shows or hides the window.</summary>
    public void Sync()
    {
        Panel.Refresh();
        if (Panel.HasContent && !IsVisible)
        {
            Show();
            if (Screens.Primary is { } screen)
            {
                var area = screen.WorkingArea;
                var scale = screen.Scaling;
                Position = new PixelPoint(
                    area.Right - (int)((Bounds.Width + Tokens.Space.Wide) * scale),
                    area.Bottom - (int)((Bounds.Height + Tokens.Space.Wide) * scale));
            }
        }
        else if (!Panel.HasContent && IsVisible)
        {
            Hide();
        }
    }

    /// <inheritdoc />
    /// <remarks>
    /// Closing hides the window so it can be reused, and never while recording: the lit lamp
    /// stays on screen for as long as Fluence records.
    /// </remarks>
    protected override void OnClosing(WindowClosingEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        if (e.CloseReason == WindowCloseReason.WindowClosing)
        {
            e.Cancel = true;
            if (!Panel.HasContent) Hide();
        }

        base.OnClosing(e);
    }
}
