namespace Murmur.Core;

/// <summary>What <see cref="AppPaths.MigrateLegacyData(string, string)"/> did.</summary>
public enum DataMigration
{
    /// <summary>There was no legacy folder; nothing to do.</summary>
    NothingToMigrate,

    /// <summary>The legacy folder was renamed in one step.</summary>
    Moved,

    /// <summary>
    /// Both folders existed; every legacy entry without a counterpart was moved across.
    /// Entries that would have overwritten something were left where they were.
    /// </summary>
    Merged,

    /// <summary>Some entries could not be moved (locked, or no permission).</summary>
    Partial,
}

/// <summary>
/// Where the app keeps its files, and the one-time move from the pre-rename folder.
/// </summary>
/// <remarks>
/// <para>
/// The product is called <b>Fluence</b>. Until October 2026 it was called Murmur, and its data
/// lived in <c>%LOCALAPPDATA%\Murmur</c>. Internal project and namespace names still say
/// <c>Murmur.*</c> — renaming them would touch every file for no user-visible gain and make
/// the rename impossible to review — but nothing a user can see does.
/// </para>
/// <para>
/// Everything is under <c>%LOCALAPPDATA%</c> (not Roaming): the speech model is ~660 MB and the
/// history is sealed with a per-machine key, so neither should follow a roaming profile.
/// </para>
/// </remarks>
public static class AppPaths
{
    /// <summary>The product name, as users see it.</summary>
    public const string ProductName = "Fluence";

    /// <summary>The folder name used before the rename.</summary>
    public const string LegacyFolderName = "Murmur";

    private static string LocalAppData =>
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    /// <summary><c>%LOCALAPPDATA%\Fluence</c>.</summary>
    public static string DataDirectory => Path.Combine(LocalAppData, ProductName);

    /// <summary><c>%LOCALAPPDATA%\Murmur</c>, the pre-rename location.</summary>
    public static string LegacyDataDirectory => Path.Combine(LocalAppData, LegacyFolderName);

    /// <summary>User preferences.</summary>
    public static string SettingsFile => Path.Combine(DataDirectory, "settings.json");

    /// <summary>The correction dictionary.</summary>
    public static string DictionaryFile => Path.Combine(DataDirectory, "dictionary.txt");

    /// <summary>The (sealed) transcript history.</summary>
    public static string TranscriptsFile => Path.Combine(DataDirectory, "transcripts.jsonl");

    /// <summary>Diagnostic logs. Never contain transcript text.</summary>
    public static string LogsDirectory => Path.Combine(DataDirectory, "logs");

    /// <summary>Where speech models are installed.</summary>
    public static string ModelsDirectory => Path.Combine(DataDirectory, "models");

    /// <summary>Moves <c>%LOCALAPPDATA%\Murmur</c> to <c>%LOCALAPPDATA%\Fluence</c>.</summary>
    public static DataMigration MigrateLegacyData() =>
        MigrateLegacyData(LegacyDataDirectory, DataDirectory);

    /// <summary>
    /// Moves everything from <paramref name="legacy"/> into <paramref name="current"/>, once.
    /// </summary>
    /// <remarks>
    /// <para>
    /// A move, never a copy: the history in the old folder is plaintext, and leaving a second
    /// copy behind would defeat sealing it.
    /// </para>
    /// <para>
    /// When only the legacy folder exists it is renamed in one step — atomic on one volume, and
    /// the common case. When both exist (a user ran a Fluence build, then found an old Murmur
    /// folder) the trees are merged and <b>nothing in the new folder is ever overwritten</b>;
    /// conflicting legacy entries stay where they are rather than being guessed at.
    /// </para>
    /// <para>Never throws. A failure here must not stop the app from starting.</para>
    /// </remarks>
    public static DataMigration MigrateLegacyData(string legacy, string current)
    {
        if (!Directory.Exists(legacy)) return DataMigration.NothingToMigrate;

        try
        {
            if (!Directory.Exists(current))
            {
                var parent = Path.GetDirectoryName(current);
                if (parent is not null) Directory.CreateDirectory(parent);

                Directory.Move(legacy, current);
                return DataMigration.Moved;
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Fall through to the entry-by-entry merge, which can make partial progress.
        }

        var complete = Merge(legacy, current);
        TryDeleteIfEmpty(legacy);
        return complete ? DataMigration.Merged : DataMigration.Partial;
    }

    /// <returns>False if anything was left behind for a reason other than a conflict.</returns>
    private static bool Merge(string from, string to)
    {
        var complete = true;

        try
        {
            Directory.CreateDirectory(to);

            foreach (var file in Directory.GetFiles(from))
            {
                var target = Path.Combine(to, Path.GetFileName(file));
                if (File.Exists(target) || Directory.Exists(target)) continue;

                try { File.Move(file, target); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { complete = false; }
            }

            foreach (var directory in Directory.GetDirectories(from))
            {
                var target = Path.Combine(to, Path.GetFileName(directory));
                if (File.Exists(target)) continue;

                if (!Directory.Exists(target))
                {
                    try
                    {
                        Directory.Move(directory, target);
                        continue;
                    }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                    {
                        // Try the slow way below.
                    }
                }

                complete &= Merge(directory, target);
                TryDeleteIfEmpty(directory);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            complete = false;
        }

        return complete;
    }

    private static void TryDeleteIfEmpty(string directory)
    {
        try
        {
            if (Directory.Exists(directory) && !Directory.EnumerateFileSystemEntries(directory).Any())
            {
                Directory.Delete(directory);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Harmless: an empty folder left behind.
        }
    }
}
