using System.Security.Cryptography;
using Murmur.Abstractions;

namespace Murmur.Platform.Windows;

/// <summary>
/// Wraps secrets with DPAPI for the current Windows user.
/// </summary>
/// <remarks>
/// A binding and nothing more: the history's actual encryption, key handling and migration
/// live in <c>Murmur.Core</c>, where CI can test them. The entropy is a fixed, app-specific
/// label so another program running as the same user cannot unwrap the blob by accident with
/// a bare <c>CryptUnprotectData</c> call.
/// </remarks>
public sealed class DpapiSecretProtector : ISecretProtector
{
    private static readonly byte[] Entropy = "Fluence transcript history key v1"u8.ToArray();

    /// <inheritdoc />
    public byte[] Protect(byte[] secret) =>
        ProtectedData.Protect(secret, Entropy, DataProtectionScope.CurrentUser);

    /// <inheritdoc />
    public byte[] Unprotect(byte[] protectedSecret) =>
        ProtectedData.Unprotect(protectedSecret, Entropy, DataProtectionScope.CurrentUser);
}
