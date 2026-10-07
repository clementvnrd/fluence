using System.Diagnostics.CodeAnalysis;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Murmur.Abstractions;

namespace Murmur.Core.Meetings;

/// <summary>
/// The Notetaker's keys: one random master key, wrapped by DPAPI for this Windows user
/// (<c>meetings.key</c>, through <see cref="HistoryCipher"/>, the FLU-2 history crypto), and
/// one random AES-256-GCM key per meeting, wrapped by the master key.
/// </summary>
/// <remarks>
/// <para>
/// Deleting a meeting deletes its wrapped key, so its files are unreadable even if a copy
/// survives on disk. Every wrap and every file is bound to a label naming what it is
/// (associated data), so a blob cannot be swapped for another meeting's or another kind.
/// </para>
/// <para>
/// <b>No plaintext fallback.</b> Without a protector (no platform layer) there is no vault, and
/// the Notetaker does not record. A master key this account cannot unwrap is set aside, never
/// deleted, and a new one started — the meetings it protected stay on disk, unreadable here.
/// </para>
/// </remarks>
public sealed class MeetingVault : IDisposable
{
    private readonly HistoryCipher _master;

    private MeetingVault(HistoryCipher master) => _master = master;

    /// <summary>The master key file in <paramref name="directory"/>.</summary>
    public static string KeyPath(string directory) => Path.Combine(directory, "meetings.key");

    /// <summary>Opens or creates the vault in <paramref name="directory"/>.</summary>
    /// <param name="directory">The meetings folder.</param>
    /// <param name="protector">DPAPI on Windows; null means no vault.</param>
    /// <param name="clock">Names a set-aside key.</param>
    /// <param name="log">Exception types only.</param>
    /// <param name="problem">A sentence for the user when something is wrong.</param>
    public static MeetingVault? Open(
        string directory, ISecretProtector? protector, IClock clock, IDiagnosticLog log, out string? problem)
    {
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(log);
        problem = null;
        if (protector is null)
        {
            problem = "Meetings cannot be recorded: no secure key storage is available on this system.";
            return null;
        }

        var path = KeyPath(directory);
        try
        {
            Directory.CreateDirectory(directory);
            return new MeetingVault(HistoryCipher.OpenOrCreate(path, protector));
        }
        catch (CryptographicException e)
        {
            log.Error("meetings.key_unreadable", e);
            var stamp = clock.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
            try
            {
                File.Move(path, Path.Combine(directory, $"meetings.unreadable-{stamp}.key"));
            }
            catch (Exception move) when (move is IOException or UnauthorizedAccessException)
            {
                log.Error("meetings.key_set_aside_failed", move);
                problem = "The meetings key could not be unlocked by this Windows account, nor set aside.";
                return null;
            }

            problem = "Earlier meetings could not be unlocked by this Windows account. They were kept, "
                    + "and new meetings use a new key.";
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            log.Error("meetings.key_io_failed", e);
            problem = "The meetings key could not be read, so meetings cannot be recorded.";
            return null;
        }

        try
        {
            return new MeetingVault(HistoryCipher.OpenOrCreate(path, protector));
        }
        catch (Exception e) when (e is CryptographicException or IOException or UnauthorizedAccessException)
        {
            log.Error("meetings.key_create_failed", e);
            problem = "A meetings key could not be created, so meetings cannot be recorded.";
            return null;
        }
    }

    /// <summary>A fresh item key, and its wrapped form to store beside the item.</summary>
    public (AesGcm Key, byte[] Wrapped) CreateItemKey(string label)
    {
        var key = RandomNumberGenerator.GetBytes(AeadBox.KeyBytes);
        try
        {
            return (new AesGcm(key, AeadBox.TagBytes), _master.SealBytes(key, Label("item-key", label)));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
        }
    }

    /// <summary>Unwraps an item key.</summary>
    /// <returns>False when the wrap is corrupt, belongs to another item, or another master key.</returns>
    public bool TryOpenItemKey(byte[] wrapped, string label, [NotNullWhen(true)] out AesGcm? key)
    {
        key = null;
        if (!_master.TryOpenBytes(wrapped, Label("item-key", label), out var raw)) return false;
        try
        {
            if (raw.Length != AeadBox.KeyBytes) return false;
            key = new AesGcm(raw, AeadBox.TagBytes);
            return true;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(raw);
        }
    }

    /// <summary>Seals a small file directly under the master key (voice prints).</summary>
    public byte[] Seal(ReadOnlySpan<byte> plaintext, string label) => _master.SealBytes(plaintext, Label("file", label));

    /// <summary>Opens what <see cref="Seal"/> produced.</summary>
    public bool TryOpen(ReadOnlySpan<byte> blob, string label, [NotNullWhen(true)] out byte[]? plaintext) =>
        _master.TryOpenBytes(blob, Label("file", label), out plaintext);

    /// <summary>The associated data binding a blob to what it is.</summary>
    public static byte[] Label(string kind, string name) => Encoding.UTF8.GetBytes($"fluence/meetings/v1/{kind}/{name}");

    /// <inheritdoc />
    public void Dispose() => _master.Dispose();
}
