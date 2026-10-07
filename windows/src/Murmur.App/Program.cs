using Avalonia;
using Murmur.Abstractions;
using Murmur.Core;

namespace Murmur.App;

/// <summary>Entry point.</summary>
public static class Program
{
    /// <summary>
    /// The app-wide diagnostic log. Discards everything until <see cref="Main"/> opens the
    /// real one, which is what the headless test host wants.
    /// </summary>
    public static IDiagnosticLog Log { get; private set; } = NullDiagnosticLog.Instance;

    /// <summary>Starts the app, or runs a headless self-test.</summary>
    /// <param name="args">Command line. <c>--selftest</c> exits without showing UI.</param>
    /// <returns>0 on success.</returns>
    [STAThread]
    public static int Main(string[] args)
    {
        PlatformFactory.InstallResolver();

        // The published single-file exe is the only artifact CI can run end to end, and a
        // GitHub runner cannot show a window. This branch exercises startup — assembly
        // loading, native library resolution out of the self-extracted bundle, model
        // discovery — and exits, which is the class of failure that only appears after
        // publishing.
        if (args.Contains("--selftest", StringComparer.OrdinalIgnoreCase))
        {
            return SelfTest.Run();
        }

        // Before anything opens a file: the pre-rename %LOCALAPPDATA%\Murmur folder is moved,
        // not copied, so its plaintext history cannot linger beside the new one. Then the log,
        // which lives inside the (now migrated) data folder.
        var migration = AppPaths.MigrateLegacyData();
        Log = new FileDiagnosticLog(AppPaths.LogsDirectory);
        if (migration != DataMigration.NothingToMigrate)
        {
            Log.Info("startup.legacy_data_migrated", new Dictionary<string, object?> { ["result"] = migration });
        }

        WatchForUnhandledExceptions(Log);

        try
        {
            return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        }
        catch (Exception e)
        {
            Log.Error("app.crashed", e);
            throw;
        }
    }

    /// <summary>
    /// Records exceptions that would otherwise disappear: a faulted task nobody awaited is
    /// otherwise silent, and an unhandled one takes the process down with no trace.
    /// </summary>
    internal static void WatchForUnhandledExceptions(IDiagnosticLog log)
    {
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            log.Error("task.unobserved", e.Exception);
            e.SetObserved();
        };

        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            log.Error("app.unhandled", e.ExceptionObject as Exception,
                new Dictionary<string, object?> { ["terminating"] = e.IsTerminating });
        };
    }

    /// <summary>Configures Avalonia. Also used by the headless test host.</summary>
    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
