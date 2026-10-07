using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Markup.Xaml;
using Avalonia.Threading;
using Murmur.Abstractions;
using Murmur.App.Views;
using Murmur.Core;

namespace Murmur.App;

/// <summary>The application.</summary>
public partial class App : Application
{
    private Composition? _composition;
    private MainWindow? _main;
    private MeetingPanelWindow? _meetingPanel;
    private DispatcherTimer? _meetingTicker;

    /// <inheritdoc />
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    /// <inheritdoc />
    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            _composition = Composition.Create(Program.Log);
            _main = new MainWindow(_composition);
            desktop.MainWindow = _main;
            StartNotetaker(_composition);

            // Clipboard paste for the injector. Without this the ClipboardPaste hook the
            // injector was designed around stays null, and multi-line dictation is typed
            // with real Enter keys — in a chat box each Enter SENDS the half-written
            // message. Found dictating into a chat app on the first real-hardware run.
            if (_composition.Injector is { } injector)
            {
                PlatformFactory.AttachClipboardPaste(injector, PasteViaClipboardAsync);
            }

            // Closing the window leaves Fluence running in the tray — the hotkey still works,
            // which is the whole point of a dictation app. Quit is explicit, from the tray
            // menu or the app menu.
            desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;

            // Disposing tears down the keyboard hook and releases the audio device. Leaving
            // a low-level hook installed after exit is the kind of thing that makes a
            // machine feel broken until it is rebooted.
            desktop.ShutdownRequested += (_, _) =>
            {
                _meetingTicker?.Stop();
                try
                {
                    _composition?.DisposeAsync().AsTask().GetAwaiter().GetResult();
                }
                catch (Exception e)
                {
                    Program.Log.Error("app.shutdown_failed", e);
                }

                _composition = null;
            };
        }

        base.OnFrameworkInitializationCompleted();
    }

    private void OnTrayShow(object? sender, EventArgs e) => ShowMain();

    private void OnTrayTakeNotes(object? sender, EventArgs e) => _main?.ToggleMeetingNotes();

    private void OnTrayMeetings(object? sender, EventArgs e)
    {
        ShowMain();
        _main?.ShowMeetings();
    }

    /// <summary>
    /// The Notetaker runs on a one-second tick on the UI thread: detection, the card's countdown,
    /// stop rules, autosave. The panel window follows the controller's state.
    /// </summary>
    private void StartNotetaker(Composition composition)
    {
        if (composition.Meetings.Controller is not { } controller) return;

        _meetingPanel = new MeetingPanelWindow(controller);
        var ticking = false;
        _meetingTicker = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _meetingTicker.Tick += async (_, _) =>
        {
            // A tick that starts or stops a recording can take longer than a second.
            if (ticking) return;
            ticking = true;
            try
            {
                await controller.TickAsync().ConfigureAwait(true);
            }
            catch (Exception e)
            {
                Program.Log.Error("meeting.tick_failed", e);
            }
            finally
            {
                ticking = false;
            }
        };
        _meetingTicker.Start();

        // Meetings a crash left unfinished, once the app has settled.
        _ = Task.Run(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            try
            {
                await controller.RecoverInterruptedAsync(CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                Program.Log.Error("meeting.recover_failed", e);
            }
        });
    }

    private void OnTraySettings(object? sender, EventArgs e)
    {
        ShowMain();
        if (_main is not null && _composition is not null)
        {
            _ = new SettingsWindow(_composition.Settings, _composition.Transcripts, _composition.Model).ShowDialog(_main);
        }
    }

    private void OnTrayQuit(object? sender, EventArgs e)
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop) desktop.Shutdown();
    }

    private void ShowMain()
    {
        if (_main is null) return;

        _main.Show();
        _main.WindowState = WindowState.Normal;
        _main.Activate();
    }

    /// <summary>
    /// Puts <paramref name="text"/> on the clipboard, pastes it with Ctrl+V, and puts the
    /// clipboard back the way it was. Atomic from the target app's point of view — no
    /// synthetic Enter ever reaches it.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Private while it is there.</b> The text goes on with the formats that keep it out of
    /// clipboard managers, Win+V history and Cloud Clipboard (<see cref="ClipboardPrivacy"/>).
    /// </para>
    /// <para>
    /// <b>Gone afterwards.</b> After the paste settles, if the clipboard still holds the
    /// dictation, the previous text is restored — or, if there was no text before, the
    /// clipboard is cleared rather than left holding the dictation. If something else was
    /// copied meanwhile, it is left alone. Non-text content (an image) cannot be put back;
    /// that is the accepted cost of not typing Enters into chat boxes.
    /// </para>
    /// <para>
    /// Runs on the UI thread because Avalonia's clipboard requires it. 60 ms for the target to
    /// observe the new clipboard, 500 ms for it to finish reading.
    /// </para>
    /// </remarks>
    private async Task<bool> PasteViaClipboardAsync(string text, CancellationToken cancellationToken)
    {
        try
        {
            return await Dispatcher.UIThread.InvokeAsync(async () =>
            {
                var clipboard = _main?.Clipboard;
                if (clipboard is null) return false;

                string? previous = null;
                try
                {
                    previous = await clipboard.TryGetTextAsync();
                }
                catch (Exception e)
                {
                    // Non-text clipboard content; nothing to restore.
                    Program.Log.Info("inject.clipboard_previous_unreadable",
                        new Dictionary<string, object?> { ["exception"] = e.GetType().Name });
                }

                await clipboard.SetDataAsync(PrivateText(text, ClipboardPrivacy.ForTransientPaste()));
                await Task.Delay(60, cancellationToken);

                if (!PlatformFactory.PressCtrlV()) return false;

                await Task.Delay(500, cancellationToken);
                await RestoreClipboardAsync(clipboard, previous, text);
                return true;
            });
        }
        catch (Exception e)
        {
            // The injector falls back to typing when paste reports failure.
            Program.Log.Warning("inject.clipboard_paste_failed", e);
            return false;
        }
    }

    private static async Task RestoreClipboardAsync(IClipboard clipboard, string? previous, string injected)
    {
        try
        {
            var current = await clipboard.TryGetTextAsync();
            switch (ClipboardPrivacy.AfterPaste(previous, current, injected))
            {
                case ClipboardRestore.RestorePrevious:
                    await clipboard.SetTextAsync(previous);
                    break;
                case ClipboardRestore.Clear:
                    await clipboard.ClearAsync();
                    break;
            }
        }
        catch (Exception e)
        {
            // Restoring is best-effort; the paste already succeeded.
            Program.Log.Warning("inject.clipboard_restore_failed", e);
        }
    }

    /// <summary>Text plus the privacy formats, as one clipboard item.</summary>
    public static DataTransfer PrivateText(string text, IReadOnlyList<(string Format, byte[] Data)> formats)
    {
        var item = new DataTransferItem();
        item.SetText(text);
        foreach (var (format, data) in formats)
        {
            item.Set(DataFormat.CreateBytesPlatformFormat(format), data);
        }

        var transfer = new DataTransfer();
        transfer.Add(item);
        return transfer;
    }
}
