using System.Security.Cryptography;
using Murmur.Speech;
using Shouldly;
using Xunit;

namespace Murmur.SpeechTests;

/// <summary>Where the model is looked for, and how its files are checked before loading.</summary>
public sealed class ModelTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"fluence-model-{Guid.NewGuid():N}");

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    private string MakeModel(string folder, Func<string, byte[]>? content = null)
    {
        var directory = Path.Combine(_root, folder);
        Directory.CreateDirectory(directory);
        foreach (var file in ParakeetTranscriber.RequiredFiles)
        {
            File.WriteAllBytes(Path.Combine(directory, file), content?.Invoke(file) ?? [1, 2, 3]);
        }

        return directory;
    }

    private static string Sha(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    [Fact]
    public void A_configured_directory_is_the_only_candidate()
    {
        ParakeetTranscriber.SearchPaths(@"D:\models\mine", _root).ShouldBe([@"D:\models\mine"]);
    }

    [Fact]
    public void Both_v3_and_v2_folders_are_searched_v3_first()
    {
        var paths = ParakeetTranscriber.SearchPaths(null, _root).ToList();

        paths[0].ShouldBe(Path.Combine(_root, "parakeet-v3"));
        paths[1].ShouldBe(Path.Combine(_root, "parakeet-v2"));
        paths.ShouldAllBe(p => Path.IsPathRooted(p));
    }

    [Fact]
    public void Locate_finds_a_v3_model()
    {
        var v3 = MakeModel("parakeet-v3");
        ParakeetTranscriber.Locate(null, _root).ShouldBe(v3);
    }

    [Fact]
    public void Locate_respects_the_configured_directory_even_if_another_model_exists()
    {
        MakeModel("parakeet-v2");
        ParakeetTranscriber.Locate(Path.Combine(_root, "elsewhere"), _root).ShouldBeNull();
    }

    [Fact]
    public void A_missing_file_is_named()
    {
        var directory = MakeModel("parakeet-v2");
        File.Delete(Path.Combine(directory, "joiner.int8.onnx"));

        var check = ModelVerifier.Verify(directory, ParakeetTranscriber.RequiredFiles, CancellationToken.None);

        check.IsUsable.ShouldBeFalse();
        check.Problem.ShouldNotBeNull().ShouldContain("joiner.int8.onnx");
    }

    [Fact]
    public void A_truncated_download_of_a_known_variant_is_caught_by_size()
    {
        // tokens.txt at v2's exact size identifies the variant; the encoder is far too small.
        var directory = MakeModel("parakeet-v2", f => f == "tokens.txt" ? new byte[9384] : [1, 2, 3]);

        var check = ModelVerifier.Verify(directory, ParakeetTranscriber.RequiredFiles, CancellationToken.None);

        check.IsUsable.ShouldBeFalse();
        check.Variant.ShouldBe(ModelManifest.ParakeetV2.Name);
        check.Problem.ShouldNotBeNull().ShouldContain("download is incomplete");
    }

    [Fact]
    public void A_checksum_file_is_honoured_and_the_result_is_cached()
    {
        var directory = MakeModel("custom", f => System.Text.Encoding.UTF8.GetBytes(f));
        File.WriteAllLines(Path.Combine(directory, ModelVerifier.ChecksumFileName),
            ParakeetTranscriber.RequiredFiles.Select(f => $"{Sha(System.Text.Encoding.UTF8.GetBytes(f))}  {f}"));

        var first = ModelVerifier.Verify(directory, ParakeetTranscriber.RequiredFiles, CancellationToken.None);
        first.IsUsable.ShouldBeTrue();
        first.Verified.ShouldBeTrue();
        File.Exists(Path.Combine(directory, ModelVerifier.StampFileName)).ShouldBeTrue();

        // Same size and timestamp: trusted from the stamp, not re-hashed (that is the point of it).
        var encoder = Path.Combine(directory, "encoder.int8.onnx");
        var stamp = File.GetLastWriteTimeUtc(encoder);
        File.WriteAllBytes(encoder, System.Text.Encoding.UTF8.GetBytes("ENCODER.INT8.ONNX"));
        File.SetLastWriteTimeUtc(encoder, stamp);
        ModelVerifier.Verify(directory, ParakeetTranscriber.RequiredFiles, CancellationToken.None).IsUsable.ShouldBeTrue();

        // Touched: re-hashed, and the corruption is found.
        File.SetLastWriteTimeUtc(encoder, stamp.AddMinutes(1));
        var after = ModelVerifier.Verify(directory, ParakeetTranscriber.RequiredFiles, CancellationToken.None);
        after.IsUsable.ShouldBeFalse();
        after.Problem.ShouldNotBeNull().ShouldContain("encoder.int8.onnx");
    }

    [Fact]
    public void An_unrecognised_model_without_a_checksum_file_loads_unverified()
    {
        var directory = MakeModel("parakeet-v2");

        var check = ModelVerifier.Verify(directory, ParakeetTranscriber.RequiredFiles, CancellationToken.None);

        check.IsUsable.ShouldBeTrue();
        check.Verified.ShouldBeFalse();
    }

    [Fact]
    public void Checksum_files_in_sha256sum_format_parse()
    {
        var hash = new string('a', 64);
        var manifest = ModelVerifier.ParseChecksums(
            $"# comment\n{hash}  tokens.txt\n{hash} *encoder.int8.onnx\nnot a line\n{hash}  ../escape.txt\n", "x");

        manifest.ShouldNotBeNull();
        manifest.Files.Select(f => f.Name).ShouldBe(["tokens.txt", "encoder.int8.onnx"]);
    }

    [Fact]
    public void Known_manifests_cover_every_required_file()
    {
        foreach (var manifest in ModelManifest.Known)
        {
            manifest.Files.Select(f => f.Name).Order().ShouldBe(ParakeetTranscriber.RequiredFiles.Order());
            manifest.Files.ShouldAllBe(f => f.Sha256.Length == 64 && f.Size > 0);
            manifest.Revision.Length.ShouldBe(40);
        }
    }

    [Fact]
    public async Task Loading_a_corrupt_model_fails_in_managed_code_before_native_code_sees_it()
    {
        var directory = MakeModel("parakeet-v2", f => f == "tokens.txt" ? new byte[9384] : [1, 2, 3]);
        await using var transcriber = new ParakeetTranscriber(directory);

        var error = await Should.ThrowAsync<InvalidDataException>(
            async () => await transcriber.LoadAsync(CancellationToken.None));

        error.Message.ShouldContain("encoder.int8.onnx");
        transcriber.IsReady.ShouldBeFalse();
    }

    /// <summary>
    /// A real P/Invoke into sherpa-onnx's native library. Proves the native DLL for this
    /// platform resolves — the same call the published self-test makes on Windows.
    /// </summary>
    [Fact]
    public void The_native_library_loads()
    {
        ParakeetTranscriber.NativeVersion().ShouldNotBeNullOrWhiteSpace();
    }
}
