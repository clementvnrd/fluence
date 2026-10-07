using System.Text;

namespace Murmur.Core;

/// <summary>
/// Replaces a file's contents all at once, so a crash or a full disk mid-write leaves either
/// the old file or the new one — never half of each.
/// </summary>
/// <remarks>
/// Writes a sibling temporary file, flushes it to disk, then renames it over the target. On
/// one volume the rename is atomic on Windows (<c>MoveFileEx</c> with
/// <c>MOVEFILE_REPLACE_EXISTING</c>) and on POSIX (<c>rename</c>). A plain
/// <c>File.WriteAllText</c> truncates first, which is how a settings file or a dictionary ends
/// up empty after a crash.
/// </remarks>
public static class AtomicFile
{
    /// <summary>UTF-8 without a byte-order mark, which every editor and the macOS build read.</summary>
    public static readonly Encoding Utf8 = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

    /// <summary>Atomically replaces <paramref name="path"/> with <paramref name="contents"/>.</summary>
    public static void WriteAllText(string path, string contents) =>
        WriteAllBytes(path, Utf8.GetBytes(contents));

    /// <summary>Atomically replaces <paramref name="path"/> with <paramref name="lines"/>.</summary>
    public static void WriteAllLines(string path, IEnumerable<string> lines)
    {
        var builder = new StringBuilder();
        foreach (var line in lines) builder.Append(line).Append('\n');
        WriteAllText(path, builder.ToString());
    }

    /// <summary>Atomically replaces <paramref name="path"/> with <paramref name="bytes"/>.</summary>
    public static void WriteAllBytes(string path, ReadOnlySpan<byte> bytes)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        Directory.CreateDirectory(directory);

        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(
                       temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                       bufferSize: 4096, FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporary, path, overwrite: true);
        }
        catch
        {
            TryDelete(temporary);
            throw;
        }
    }

    /// <summary>
    /// Creates <paramref name="path"/> with <paramref name="bytes"/> only if it does not exist.
    /// </summary>
    /// <returns>False if another writer created it first; its contents are left untouched.</returns>
    public static bool TryCreate(string path, ReadOnlySpan<byte> bytes)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        Directory.CreateDirectory(directory);

        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(
                       temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                       bufferSize: 4096, FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporary, path, overwrite: false);
            return true;
        }
        catch (IOException) when (File.Exists(path))
        {
            TryDelete(temporary);
            return false;
        }
        catch
        {
            TryDelete(temporary);
            throw;
        }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { /* best effort */ }
    }
}
