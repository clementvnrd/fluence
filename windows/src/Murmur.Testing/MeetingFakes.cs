using System.Runtime.CompilerServices;
using Murmur.Abstractions;

namespace Murmur.Testing;

/// <summary>
/// A loopback binding that refuses the requests a test says it refuses and plays back scripted
/// packets for the first one it accepts.
/// </summary>
public sealed class FakeLoopbackCapture : ILoopbackCapture
{
    private readonly Func<LoopbackRequest, bool> _accepts;
    private readonly Func<LoopbackRequest, IReadOnlyList<RawAudioPacket>> _packets;

    /// <summary>Creates the fake.</summary>
    /// <param name="accepts">Which requests open; the rest throw like a refused COM activation.</param>
    /// <param name="packets">What an opened stream delivers.</param>
    public FakeLoopbackCapture(
        Func<LoopbackRequest, bool> accepts,
        Func<LoopbackRequest, IReadOnlyList<RawAudioPacket>>? packets = null)
    {
        _accepts = accepts;
        _packets = packets ?? (_ => []);
    }

    /// <summary>Every request tried, in order.</summary>
    public List<LoopbackRequest> Attempts { get; } = [];

    /// <inheritdoc />
    public Task<ILoopbackSession> OpenAsync(LoopbackRequest request, CancellationToken cancellationToken)
    {
        Attempts.Add(request);
        if (!_accepts(request)) throw new InvalidOperationException("Loopback activation failed (0x80070057).");
        return Task.FromResult<ILoopbackSession>(new Session(request, _packets(request)));
    }

    /// <summary>Interleaved 16-bit PCM of <paramref name="mono"/> duplicated on every channel.</summary>
    public static RawAudioPacket Pcm16(float[] mono, int sampleRate, int channels, long hostTime)
    {
        ArgumentNullException.ThrowIfNull(mono);
        var format = new PcmFormat(sampleRate, channels, 16, false);
        var bytes = new byte[mono.Length * format.BlockAlign];
        for (var frame = 0; frame < mono.Length; frame++)
        {
            var value = (short)Math.Clamp(Math.Round(mono[frame] * 32767.0), short.MinValue, short.MaxValue);
            for (var channel = 0; channel < channels; channel++)
            {
                var offset = (frame * format.BlockAlign) + (channel * 2);
                bytes[offset] = (byte)(value & 0xFF);
                bytes[offset + 1] = (byte)((value >> 8) & 0xFF);
            }
        }

        return new RawAudioPacket(bytes, mono.Length, format, hostTime, false, false);
    }

    private sealed class Session(LoopbackRequest request, IReadOnlyList<RawAudioPacket> packets) : ILoopbackSession
    {
        public LoopbackRequest Request { get; } = request;

        public async IAsyncEnumerable<RawAudioPacket> ReadAsync([EnumeratorCancellation] CancellationToken stopRequested)
        {
            foreach (var packet in packets)
            {
                await Task.Yield();
                yield return packet;
            }
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}

/// <summary>A host clock a test sets by hand (100-ns units).</summary>
public sealed class FakeHostClock : IHostClock
{
    /// <inheritdoc />
    public long Now { get; set; }

    /// <summary>Moves the clock forward by <paramref name="seconds"/>.</summary>
    public void Advance(double seconds) => Now += (long)(seconds * 10_000_000);
}

/// <summary>Meeting-detection signals a test scripts.</summary>
public sealed class FakeMeetingSignals : IMeetingSignals
{
    /// <summary>What <see cref="CaptureSessions"/> returns.</summary>
    public List<AudioSessionInfo> Sessions { get; } = [];

    /// <summary>What <see cref="VisibleWindows"/> returns.</summary>
    public List<WindowInfo> Windows { get; } = [];

    /// <summary>What <see cref="ProcessesNamed"/> returns, by name.</summary>
    public Dictionary<string, List<ProcessStart>> Processes { get; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Thrown by <see cref="CaptureSessions"/> when set.</summary>
    public Exception? Failure { get; set; }

    /// <inheritdoc />
    public IReadOnlyList<AudioSessionInfo> CaptureSessions() => Failure is null ? [.. Sessions] : throw Failure;

    /// <inheritdoc />
    public IReadOnlyList<WindowInfo> VisibleWindows() => [.. Windows];

    /// <inheritdoc />
    public IReadOnlyList<ProcessStart> ProcessesNamed(string processName) =>
        Processes.TryGetValue(processName, out var list) ? [.. list] : [];
}
