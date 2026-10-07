using System.Globalization;
using System.Security.Cryptography;

namespace Murmur.Speech;

/// <summary>One file the model is expected to contain.</summary>
/// <param name="Name">File name within the model directory.</param>
/// <param name="Size">Exact size in bytes, or null when only the hash is known.</param>
/// <param name="Sha256">Lower-case hex SHA-256.</param>
public sealed record ModelFile(string Name, long? Size, string Sha256);

/// <summary>A published model variant and the exact files it consists of.</summary>
/// <param name="Name">Human-readable variant name.</param>
/// <param name="Repository">The Hugging Face repository.</param>
/// <param name="Revision">The commit the hashes were taken from.</param>
/// <param name="Files">The required files.</param>
public sealed record ModelManifest(string Name, string Repository, string Revision, IReadOnlyList<ModelFile> Files)
{
    /// <summary>Parakeet TDT 0.6B v2 (English), int8, at a pinned commit.</summary>
    /// <remarks>Sizes and hashes from the Hugging Face API (LFS <c>oid</c>) at this revision;
    /// <c>tokens.txt</c> is not in LFS and was hashed after download, its git blob id checked.</remarks>
    public static ModelManifest ParakeetV2 { get; } = new(
        "Parakeet TDT 0.6B v2 (English)",
        "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8",
        "1ab9323565ddb038682214b292f588070a538ce2",
        [
            new("encoder.int8.onnx", 652184296, "a32b12d17bbbc309d0686fbbcc2987b5e9b8333a7da83fa6b089f0a2acd651ab"),
            new("decoder.int8.onnx", 7257753, "b6bb64963457237b900e496ee9994b59294526439fbcc1fecf705b31a15c6b4e"),
            new("joiner.int8.onnx", 1739080, "7946164367946e7f9f29a122407c3252b680dbae9a51343eb2488d057c3c43d2"),
            new("tokens.txt", 9384, "ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d"),
        ]);

    /// <summary>Parakeet TDT 0.6B v3 (25 European languages), int8, at a pinned commit.</summary>
    public static ModelManifest ParakeetV3 { get; } = new(
        "Parakeet TDT 0.6B v3 (multilingual)",
        "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
        "2bda32ec70b097a55adaa07d9a7173915b43cc78",
        [
            new("encoder.int8.onnx", 652184281, "acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247"),
            new("decoder.int8.onnx", 11845275, "179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e"),
            new("joiner.int8.onnx", 6355277, "3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3"),
            new("tokens.txt", 93939, "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"),
        ]);

    /// <summary>Every variant this build knows the hashes of.</summary>
    public static IReadOnlyList<ModelManifest> Known { get; } = [ParakeetV2, ParakeetV3];
}

/// <summary>The outcome of checking a model directory.</summary>
/// <param name="IsUsable">Whether loading should be attempted.</param>
/// <param name="Problem">Why not, in words a user can act on; null when usable.</param>
/// <param name="Variant">Which known variant matched, or null if unrecognised.</param>
/// <param name="Verified">True when every file's SHA-256 matched a manifest.</param>
public sealed record ModelCheck(bool IsUsable, string? Problem, string? Variant, bool Verified);

/// <summary>
/// Checks model files against a manifest before they reach native code.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why this exists:</b> a truncated or corrupted <c>encoder.int8.onnx</c> does not fail
/// politely. ONNX Runtime reports an opaque protobuf error at best, and native code can abort
/// the whole process at worst — a failure no <c>catch</c> can intercept. Checking in managed
/// code first turns that into a sentence in Settings.
/// </para>
/// <para>
/// <b>Which manifest.</b> A <c>SHA256SUMS</c> file in the model directory (the format
/// <c>sha256sum</c> writes) wins — the download instructions in
/// <c>docs/PARAKEET-WINDOWS.md</c> create one. Otherwise the variant is recognised from the
/// size of <c>tokens.txt</c> and checked against the hashes built into this class. A directory
/// matching neither is loaded unverified: verification is a safety net, not a lock.
/// </para>
/// <para>
/// <b>Cost.</b> Hashing 660 MB takes a second or two, so it is done once: a
/// <c>.fluence-verified</c> stamp records each file's size and modification time, and a file
/// that has not changed since is not hashed again. If the directory is read-only the stamp is
/// simply not written and the check repeats on the next start.
/// </para>
/// </remarks>
public static class ModelVerifier
{
    /// <summary>Optional per-directory manifest, in <c>sha256sum</c> format.</summary>
    public const string ChecksumFileName = "SHA256SUMS";

    /// <summary>Records which files were already verified.</summary>
    public const string StampFileName = ".fluence-verified";

    /// <summary>Checks <paramref name="directory"/>.</summary>
    public static ModelCheck Verify(string directory, IReadOnlyList<string> requiredFiles, CancellationToken cancellationToken)
    {
        var missing = requiredFiles.Where(f => !File.Exists(Path.Combine(directory, f))).ToList();
        if (missing.Count > 0)
        {
            return new ModelCheck(false, $"Missing from {directory}: {string.Join(", ", missing)}.", null, false);
        }

        var manifest = ReadChecksumFile(directory) ?? Recognise(directory);
        if (manifest is null) return new ModelCheck(true, null, null, false);

        var stamp = ReadStamp(directory);
        var stampChanged = false;

        foreach (var expected in manifest.Files)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var info = new FileInfo(Path.Combine(directory, expected.Name));
            if (!info.Exists)
            {
                return new ModelCheck(false, $"{expected.Name} is missing from {directory}.", manifest.Name, false);
            }

            if (expected.Size is { } size && info.Length != size)
            {
                return new ModelCheck(false,
                    string.Create(CultureInfo.InvariantCulture,
                        $"{expected.Name} is {info.Length:N0} bytes but should be {size:N0} — the download is incomplete or corrupt. Delete it and download it again."),
                    manifest.Name, false);
            }

            var key = StampKey(info);
            if (stamp.TryGetValue(expected.Name, out var recorded) && recorded == $"{key} {expected.Sha256}") continue;

            var actual = Hash(info.FullName, cancellationToken);
            if (!string.Equals(actual, expected.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                return new ModelCheck(false,
                    $"{expected.Name} does not match the published file (SHA-256 differs) — it is corrupt or a different version. Delete it and download it again.",
                    manifest.Name, false);
            }

            stamp[expected.Name] = $"{key} {expected.Sha256}";
            stampChanged = true;
        }

        if (stampChanged) WriteStamp(directory, stamp);
        return new ModelCheck(true, null, manifest.Name, true);
    }

    /// <summary>Parses <c>sha256sum</c> output: <c>&lt;hex&gt;  &lt;name&gt;</c>, optionally <c>*name</c>.</summary>
    public static ModelManifest? ParseChecksums(string text, string name)
    {
        var files = new List<ModelFile>();

        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;

            var space = line.IndexOf(' ', StringComparison.Ordinal);
            if (space != 64) continue;

            var hash = line[..64];
            if (!hash.All(Uri.IsHexDigit)) continue;

            var file = line[space..].Trim().TrimStart('*');
            if (file.Length == 0 || file.Contains('/', StringComparison.Ordinal) || file.Contains('\\', StringComparison.Ordinal)) continue;

            files.Add(new ModelFile(file, null, hash.ToLowerInvariant()));
        }

        return files.Count == 0 ? null : new ModelManifest(name, "", "", files);
    }

    private static ModelManifest? ReadChecksumFile(string directory)
    {
        var path = Path.Combine(directory, ChecksumFileName);
        if (!File.Exists(path)) return null;

        try
        {
            return ParseChecksums(File.ReadAllText(path), ChecksumFileName);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>Picks the known variant whose <c>tokens.txt</c> has this directory's size.</summary>
    private static ModelManifest? Recognise(string directory)
    {
        var tokens = new FileInfo(Path.Combine(directory, "tokens.txt"));
        if (!tokens.Exists) return null;

        return ModelManifest.Known.FirstOrDefault(m =>
            m.Files.Any(f => f.Name == "tokens.txt" && f.Size == tokens.Length));
    }

    private static string StampKey(FileInfo info) =>
        string.Create(CultureInfo.InvariantCulture, $"{info.Length} {info.LastWriteTimeUtc.Ticks}");

    private static string Hash(string path, CancellationToken cancellationToken)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            bufferSize: 1 << 20, FileOptions.SequentialScan);
        using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);

        var buffer = new byte[1 << 20];
        int read;
        while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
        {
            cancellationToken.ThrowIfCancellationRequested();
            sha.AppendData(buffer, 0, read);
        }

        return Convert.ToHexStringLower(sha.GetHashAndReset());
    }

    private static Dictionary<string, string> ReadStamp(string directory)
    {
        var stamp = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            var path = Path.Combine(directory, StampFileName);
            if (!File.Exists(path)) return stamp;

            foreach (var line in File.ReadAllLines(path))
            {
                var tab = line.IndexOf('\t', StringComparison.Ordinal);
                if (tab > 0) stamp[line[..tab]] = line[(tab + 1)..];
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            stamp.Clear();
        }

        return stamp;
    }

    private static void WriteStamp(string directory, Dictionary<string, string> stamp)
    {
        try
        {
            File.WriteAllLines(Path.Combine(directory, StampFileName),
                stamp.Select(kv => $"{kv.Key}\t{kv.Value}"));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Read-only install: verify again next time.
        }
    }
}
