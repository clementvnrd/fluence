using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Murmur.Abstractions;
using Murmur.Meeting;

namespace Murmur.Core.Meetings;

/// <summary>
/// Meeting audio on disk, encrypted, appended as it is captured — never one growing array in
/// memory. Port of <c>MeetingAudioSpool.swift</c>.
/// </summary>
/// <remarks>
/// <para>
/// One file per channel, <c>&lt;meeting&gt;\audio-mic.spool</c> and <c>audio-system.spool</c>,
/// sealed with the meeting's own key, so deleting the meeting makes its audio unreadable.
/// Deleted after the final pass unless the meeting keeps its audio. Sample <i>i</i> is meeting
/// time <i>i</i> / 16 000.
/// </para>
/// <para>Format (little-endian):</para>
/// <code>
/// header   "FLSP" | version u32 = 1 | sampleRate u32 | samplesPerRecord u32
/// record*  sealedLength u32 | nonce(12) | ciphertext | tag(16)  of samplesPerRecord Int16 samples
/// </code>
/// <para>
/// Each record's associated data names the meeting, the channel and the record's index, so
/// records cannot be reordered or moved between files. A record cut short by a crash fails
/// authentication and reads as silence.
/// </para>
/// </remarks>
public sealed class MeetingAudioSpool : IAudioSpoolWriter, IDisposable
{
    /// <summary>Samples per sealed record: one second.</summary>
    public const int SamplesPerRecord = AudioChunk.SampleRate;

    internal const int HeaderSize = 16;
    internal static ReadOnlySpan<byte> Magic => "FLSP"u8;

    private readonly FileStream _file;
    private readonly AesGcm _key;
    private readonly Guid _meeting;
    private readonly AudioSource _source;
    private readonly short[] _pending = new short[SamplesPerRecord];
    private readonly Lock _sync = new();
    private int _fill;
    private long _records;
    private bool _closed;

    /// <summary>Creates (truncating) the spool for one channel.</summary>
    /// <param name="path">The file.</param>
    /// <param name="key">The meeting's key. Not owned.</param>
    /// <param name="meeting">Bound into every record.</param>
    /// <param name="source">Bound into every record.</param>
    public MeetingAudioSpool(string path, AesGcm key, Guid meeting, AudioSource source)
    {
        _key = key;
        _meeting = meeting;
        _source = source;
        _file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
        Span<byte> header = stackalloc byte[HeaderSize];
        Magic.CopyTo(header);
        BinaryPrimitives.WriteUInt32LittleEndian(header[4..], 1);
        BinaryPrimitives.WriteUInt32LittleEndian(header[8..], AudioChunk.SampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(header[12..], SamplesPerRecord);
        _file.Write(header);
        _file.Flush();
    }

    /// <summary>The file for <paramref name="source"/> in a meeting folder.</summary>
    public static string PathFor(string directory, AudioSource source) =>
        Path.Combine(directory, source == AudioSource.Microphone ? "audio-mic.spool" : "audio-system.spool");

    /// <summary>Samples appended so far.</summary>
    public long SampleCount { get; private set; }

    /// <inheritdoc />
    /// <remarks>Full records are sealed and written immediately: at most one second per channel is held in memory.</remarks>
    public void Append(ReadOnlySpan<float> samples)
    {
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_closed, this);
            foreach (var sample in samples)
            {
                _pending[_fill++] = (short)(Math.Clamp(sample, -1f, 1f) * short.MaxValue);
                if (_fill == SamplesPerRecord) WriteRecordLocked();
            }

            SampleCount += samples.Length;
        }
    }

    /// <summary>Writes the last partial record and closes the file.</summary>
    public void Dispose()
    {
        lock (_sync)
        {
            if (_closed) return;
            _closed = true;
            try
            {
                if (_fill > 0) WriteRecordLocked();
            }
            finally
            {
                _file.Dispose();
            }
        }
    }

    internal static byte[] AssociatedData(Guid meeting, AudioSource source, long index) => Encoding.UTF8.GetBytes(
        string.Create(CultureInfo.InvariantCulture, $"fluence/meetings/v1/spool/{meeting:D}/{source}/{index}"));

    private void WriteRecordLocked()
    {
        var plain = new byte[_fill * 2];
        for (var i = 0; i < _fill; i++) BinaryPrimitives.WriteInt16LittleEndian(plain.AsSpan(i * 2), _pending[i]);
        var sealedRecord = AeadBox.Seal(_key, plain, AssociatedData(_meeting, _source, _records));
        Span<byte> length = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(length, (uint)sealedRecord.Length);
        _file.Write(length);
        _file.Write(sealedRecord);
        _file.Flush();
        _records++;
        _fill = 0;
    }
}

/// <summary>
/// Random access to a spool. Thread-safe; caches the last decrypted record, which sequential
/// readers hit almost every time. Positions past the end, or in a damaged record, read as silence.
/// </summary>
public sealed class MeetingAudioSpoolReader : IAudioSpoolReader, IDisposable
{
    private readonly FileStream _file;
    private readonly AesGcm _key;
    private readonly Guid _meeting;
    private readonly AudioSource _source;
    private readonly int _perRecord;
    private readonly int _recordSize;
    private readonly Lock _sync = new();
    private long _cachedIndex = -1;
    private short[] _cached = [];

    private MeetingAudioSpoolReader(FileStream file, AesGcm key, Guid meeting, AudioSource source, int perRecord, long count)
    {
        _file = file;
        _key = key;
        _meeting = meeting;
        _source = source;
        _perRecord = perRecord;
        _recordSize = 4 + AeadBox.NonceBytes + (perRecord * 2) + AeadBox.TagBytes;
        SampleCount = count;
    }

    /// <inheritdoc />
    public long SampleCount { get; }

    /// <summary>Opens a spool; null when the file is missing or not a spool.</summary>
    /// <param name="path">The file.</param>
    /// <param name="key">The meeting's key. Not owned.</param>
    /// <param name="meeting">The meeting it belongs to.</param>
    /// <param name="source">The channel it holds.</param>
    public static MeetingAudioSpoolReader? Open(string path, AesGcm key, Guid meeting, AudioSource source)
    {
        if (!File.Exists(path)) return null;
        var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        Span<byte> header = stackalloc byte[MeetingAudioSpool.HeaderSize];
        if (file.ReadAtLeast(header, header.Length, throwOnEndOfStream: false) != header.Length
            || !header[..4].SequenceEqual(MeetingAudioSpool.Magic))
        {
            file.Dispose();
            return null;
        }

        var perRecord = (int)BinaryPrimitives.ReadUInt32LittleEndian(header[12..]);
        if (perRecord is <= 0 or > 10 * AudioChunk.SampleRate)
        {
            file.Dispose();
            return null;
        }

        var recordSize = 4 + AeadBox.NonceBytes + (perRecord * 2) + AeadBox.TagBytes;
        var body = Math.Max(0, file.Length - MeetingAudioSpool.HeaderSize);
        var count = body / recordSize * perRecord;
        var tail = body % recordSize;
        if (tail > 4 + AeadBox.NonceBytes + AeadBox.TagBytes)
        {
            // A partial last record: its own length field says how much it holds.
            file.Position = MeetingAudioSpool.HeaderSize + (body / recordSize * recordSize);
            Span<byte> length = stackalloc byte[4];
            if (file.ReadAtLeast(length, 4, throwOnEndOfStream: false) == 4)
            {
                var sealedLength = BinaryPrimitives.ReadUInt32LittleEndian(length);
                var overhead = AeadBox.NonceBytes + AeadBox.TagBytes;
                if (sealedLength <= tail - 4 && sealedLength > overhead) count += (sealedLength - overhead) / 2;
            }
        }

        return new MeetingAudioSpoolReader(file, key, meeting, source, perRecord, count);
    }

    /// <inheritdoc />
    public int Read(long start, Span<float> destination)
    {
        lock (_sync)
        {
            if (start >= SampleCount || start < 0) return 0;
            var count = (int)Math.Min(destination.Length, SampleCount - start);
            var written = 0;
            while (written < count)
            {
                var position = start + written;
                var index = position / _perRecord;
                var within = (int)(position % _perRecord);
                var record = Record(index);
                var available = Math.Min(_perRecord - within, count - written);
                for (var i = 0; i < available; i++)
                {
                    destination[written + i] = within + i < record.Length ? record[within + i] / (float)short.MaxValue : 0f;
                }

                written += available;
            }

            return count;
        }
    }

    /// <inheritdoc />
    public void Dispose() => _file.Dispose();

    private short[] Record(long index)
    {
        if (index == _cachedIndex) return _cached;
        _cachedIndex = index;
        _cached = [];
        try
        {
            _file.Position = MeetingAudioSpool.HeaderSize + (index * _recordSize);
            Span<byte> length = stackalloc byte[4];
            if (_file.ReadAtLeast(length, 4, throwOnEndOfStream: false) != 4) return _cached;
            var sealedLength = (int)BinaryPrimitives.ReadUInt32LittleEndian(length);
            if (sealedLength <= AeadBox.NonceBytes + AeadBox.TagBytes || sealedLength > _recordSize - 4) return _cached;
            var blob = new byte[sealedLength];
            if (_file.ReadAtLeast(blob, sealedLength, throwOnEndOfStream: false) != sealedLength) return _cached;
            if (!AeadBox.TryOpen(_key, blob, MeetingAudioSpool.AssociatedData(_meeting, _source, index), out var plain)) return _cached;
            var samples = new short[plain.Length / 2];
            for (var i = 0; i < samples.Length; i++) samples[i] = BinaryPrimitives.ReadInt16LittleEndian(plain.AsSpan(i * 2));
            _cached = samples;
        }
        catch (IOException)
        {
            // Read as silence; the spool is best-effort evidence for the final pass.
        }

        return _cached;
    }
}
