using System.Diagnostics.CodeAnalysis;
using System.Security.Cryptography;
using System.Text;
using Murmur.Abstractions;

namespace Murmur.Core;

/// <summary>
/// Seals individual history lines with AES-256-GCM under a key that only the current Windows
/// user can unwrap.
/// </summary>
/// <remarks>
/// <para>
/// <b>Two layers, on purpose.</b> The 256-bit data key is random and lives in a small file
/// beside the history, wrapped by an <see cref="ISecretProtector"/> (DPAPI on Windows). The
/// lines themselves are sealed here, in platform-neutral code that CI can test. A stolen
/// laptop image, a backup, or another account on the same machine sees only ciphertext.
/// </para>
/// <para>
/// <b>Per line, not per file,</b> so appending a dictation stays an append: no reading,
/// decrypting and rewriting the whole history on every utterance. Each line is
/// <c>f1:</c> + base64(nonce ‖ ciphertext ‖ tag), with a fresh random 96-bit nonce and a
/// fixed associated-data label so a line cannot be replayed into some other file format.
/// </para>
/// </remarks>
public sealed class HistoryCipher : IDisposable
{
    /// <summary>Marks a sealed line, and versions the format.</summary>
    public const string Prefix = "f1:";

    private const int KeyBytes = 32;
    private const int NonceBytes = 12;
    private const int TagBytes = 16;

    private static readonly byte[] AssociatedData = "fluence/transcripts/v1"u8.ToArray();

    private readonly AesGcm _aes;
    private readonly Lock _sync = new();

    private HistoryCipher(byte[] key)
    {
        _aes = new AesGcm(key, TagBytes);
        CryptographicOperations.ZeroMemory(key);
    }

    /// <summary>
    /// Unwraps the key at <paramref name="keyPath"/>, or creates one if there is none.
    /// </summary>
    /// <exception cref="CryptographicException">
    /// The key exists but cannot be unwrapped — it belongs to another user or machine, or is
    /// damaged. The caller decides what to do with the history it protected; this never
    /// overwrites a key it could not read.
    /// </exception>
    public static HistoryCipher OpenOrCreate(string keyPath, ISecretProtector protector)
    {
        if (!File.Exists(keyPath))
        {
            var fresh = RandomNumberGenerator.GetBytes(KeyBytes);
            if (AtomicFile.TryCreate(keyPath, protector.Protect(fresh))) return new HistoryCipher(fresh);

            // Lost a creation race to another instance: use the key it wrote.
            CryptographicOperations.ZeroMemory(fresh);
        }

        var key = protector.Unprotect(File.ReadAllBytes(keyPath));
        if (key.Length != KeyBytes)
        {
            CryptographicOperations.ZeroMemory(key);
            throw new CryptographicException("The history key has the wrong length.");
        }

        return new HistoryCipher(key);
    }

    /// <summary>Whether <paramref name="line"/> is in the sealed format.</summary>
    public static bool IsSealed(string line) => line.StartsWith(Prefix, StringComparison.Ordinal);

    /// <summary>Encrypts one line.</summary>
    public string Seal(string plaintext)
    {
        var plain = Encoding.UTF8.GetBytes(plaintext);
        var blob = new byte[NonceBytes + plain.Length + TagBytes];
        var nonce = blob.AsSpan(0, NonceBytes);
        RandomNumberGenerator.Fill(nonce);

        lock (_sync)
        {
            _aes.Encrypt(
                nonce,
                plain,
                blob.AsSpan(NonceBytes, plain.Length),
                blob.AsSpan(NonceBytes + plain.Length, TagBytes),
                AssociatedData);
        }

        CryptographicOperations.ZeroMemory(plain);
        return Prefix + Convert.ToBase64String(blob);
    }

    /// <summary>Decrypts one line.</summary>
    /// <returns>False if the line is not sealed, is corrupt, or was sealed under another key.</returns>
    public bool TryOpen(string line, [NotNullWhen(true)] out string? plaintext)
    {
        plaintext = null;
        if (!IsSealed(line)) return false;

        byte[] blob;
        try
        {
            blob = Convert.FromBase64String(line[Prefix.Length..]);
        }
        catch (FormatException)
        {
            return false;
        }

        if (blob.Length < NonceBytes + TagBytes) return false;

        var length = blob.Length - NonceBytes - TagBytes;
        var plain = new byte[length];

        try
        {
            lock (_sync)
            {
                _aes.Decrypt(
                    blob.AsSpan(0, NonceBytes),
                    blob.AsSpan(NonceBytes, length),
                    blob.AsSpan(NonceBytes + length, TagBytes),
                    plain,
                    AssociatedData);
            }
        }
        catch (CryptographicException)
        {
            // Tag mismatch: tampered, truncated, or another key.
            return false;
        }

        plaintext = Encoding.UTF8.GetString(plain);
        CryptographicOperations.ZeroMemory(plain);
        return true;
    }

    /// <inheritdoc />
    public void Dispose() => _aes.Dispose();
}
