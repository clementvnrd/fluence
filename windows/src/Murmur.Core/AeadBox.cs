using System.Diagnostics.CodeAnalysis;
using System.Security.Cryptography;

namespace Murmur.Core;

/// <summary>
/// AES-256-GCM with a fresh random 96-bit nonce per message: <c>nonce ‖ ciphertext ‖ tag</c>.
/// The byte-level primitive under <see cref="HistoryCipher"/>'s lines and the meeting store's
/// files and wrapped keys.
/// </summary>
public static class AeadBox
{
    /// <summary>Key length, bytes.</summary>
    public const int KeyBytes = 32;

    /// <summary>Nonce length, bytes.</summary>
    public const int NonceBytes = 12;

    /// <summary>Tag length, bytes.</summary>
    public const int TagBytes = 16;

    /// <summary>Encrypts <paramref name="plaintext"/> bound to <paramref name="associatedData"/>.</summary>
    public static byte[] Seal(AesGcm aes, ReadOnlySpan<byte> plaintext, ReadOnlySpan<byte> associatedData)
    {
        ArgumentNullException.ThrowIfNull(aes);
        var blob = new byte[NonceBytes + plaintext.Length + TagBytes];
        var nonce = blob.AsSpan(0, NonceBytes);
        RandomNumberGenerator.Fill(nonce);
        aes.Encrypt(nonce, plaintext, blob.AsSpan(NonceBytes, plaintext.Length),
            blob.AsSpan(NonceBytes + plaintext.Length, TagBytes), associatedData);
        return blob;
    }

    /// <summary>Decrypts what <see cref="Seal"/> produced.</summary>
    /// <returns>False when the blob is truncated, tampered with, sealed under another key or other associated data.</returns>
    public static bool TryOpen(AesGcm aes, ReadOnlySpan<byte> blob, ReadOnlySpan<byte> associatedData,
        [NotNullWhen(true)] out byte[]? plaintext)
    {
        ArgumentNullException.ThrowIfNull(aes);
        plaintext = null;
        if (blob.Length < NonceBytes + TagBytes) return false;

        var length = blob.Length - NonceBytes - TagBytes;
        var plain = new byte[length];
        try
        {
            aes.Decrypt(blob[..NonceBytes], blob.Slice(NonceBytes, length), blob.Slice(NonceBytes + length, TagBytes),
                plain, associatedData);
        }
        catch (CryptographicException)
        {
            return false;
        }

        plaintext = plain;
        return true;
    }
}
