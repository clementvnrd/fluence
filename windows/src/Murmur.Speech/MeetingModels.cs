namespace Murmur.Speech;

/// <summary>
/// The optional models the meeting Notetaker uses beside Parakeet: Silero VAD, pyannote
/// segmentation 3.0 and a WeSpeaker embedding model. Each is pinned to a Hugging Face commit
/// with its size and SHA-256 (from the API's LFS <c>oid</c>, checked by download), and each is
/// optional: without VAD the pipeline cuts on energy, without diarization remote speech stays
/// "Others". See <c>docs/PARAKEET-WINDOWS.md</c> → Meeting models.
/// </summary>
public static class MeetingModels
{
    /// <summary>Silero VAD, as packaged for sherpa-onnx. ~1.8 MB, MIT.</summary>
    public static ModelManifest SileroVad { get; } = new(
        "Silero VAD",
        "csukuangfj/vad",
        "fba88cd2e921609e7675c3aaf51e0b9b295da4bc",
        [new("silero_vad.onnx", 1807522, "a35ebf52fd3ce5f1469b2a36158dba761bc47b973ea3382b3186ca15b1f5af28")]);

    /// <summary>pyannote segmentation 3.0, exported for sherpa-onnx. ~6 MB, MIT. Saved as <c>segmentation.onnx</c>.</summary>
    public static ModelManifest Segmentation { get; } = new(
        "pyannote segmentation 3.0",
        "csukuangfj/sherpa-onnx-pyannote-segmentation-3-0",
        "9403a6902bb58e3d5ae8c7e77c3422de279db2e0",
        [new("segmentation.onnx", 5992913, "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079")]);

    /// <summary>
    /// WeSpeaker ResNet34-LM trained on VoxCeleb (the embedding family the macOS diarizer uses).
    /// ~26.5 MB. Saved as <c>embedding.onnx</c>. Licence of the pretrained weights to be confirmed
    /// with WeSpeaker before redistributing (the VoxCeleb data is CC BY 4.0).
    /// </summary>
    public static ModelManifest Embedding { get; } = new(
        "WeSpeaker ResNet34-LM (VoxCeleb)",
        "csukuangfj/speaker-embedding-models",
        "0743f301363dec56491a490f6d6cbc9d67f9a3bf",
        [new("embedding.onnx", 26530550, "e9848563da86f263117134dfd7ad63c92355b37de492b55e325400c9d9c39012")]);

    /// <summary>Folder under the models root for the VAD.</summary>
    public const string VadFolder = "silero-vad";

    /// <summary>Folder under the models root for the two diarization models.</summary>
    public const string DiarizationFolder = "diarization";

    /// <summary>The VAD model file, when installed under <paramref name="modelsRoot"/>.</summary>
    public static string? LocateVad(string modelsRoot) =>
        Existing(Path.Combine(modelsRoot, VadFolder, "silero_vad.onnx"));

    /// <summary>The diarization folder, when both of its files are installed under <paramref name="modelsRoot"/>.</summary>
    public static string? LocateDiarization(string modelsRoot)
    {
        var folder = Path.Combine(modelsRoot, DiarizationFolder);
        return File.Exists(Path.Combine(folder, "segmentation.onnx")) && File.Exists(Path.Combine(folder, "embedding.onnx"))
            ? folder
            : null;
    }

    /// <summary>Checks a model folder against <paramref name="manifests"/> before native code sees it.</summary>
    public static ModelCheck Verify(string folder, IReadOnlyList<ModelManifest> manifests, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(manifests);
        var combined = new ModelManifest(
            string.Join(" + ", manifests.Select(m => m.Name)), "", "", [.. manifests.SelectMany(m => m.Files)]);
        return ModelVerifier.Verify(folder, [.. combined.Files.Select(f => f.Name)], combined, cancellationToken);
    }

    private static string? Existing(string path) => File.Exists(path) ? path : null;
}
