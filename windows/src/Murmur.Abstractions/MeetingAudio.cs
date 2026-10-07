using System.Diagnostics;

namespace Murmur.Abstractions;

/// <summary>The layout of raw PCM samples.</summary>
/// <param name="SampleRate">Frames per second.</param>
/// <param name="Channels">Interleaved channels per frame.</param>
/// <param name="BitsPerSample">16, 24 or 32.</param>
/// <param name="IsFloat">IEEE float (32-bit only) rather than signed integers.</param>
public readonly record struct PcmFormat(int SampleRate, int Channels, int BitsPerSample, bool IsFloat)
{
    /// <summary>16 kHz mono 32-bit float — what every speech model here wants.</summary>
    public static PcmFormat SpeechFloat => new(AudioChunk.SampleRate, 1, 32, true);

    /// <summary>Bytes per frame.</summary>
    public int BlockAlign => Channels * (BitsPerSample / 8);
}

/// <summary>One packet from a capture device, exactly as the device delivered it.</summary>
/// <param name="Data">Interleaved samples in <paramref name="Format"/>. Owned by the receiver.</param>
/// <param name="Frames">Frames in the packet. When <paramref name="IsSilent"/>, <paramref name="Data"/> may be empty.</param>
/// <param name="Format">The packet's sample layout.</param>
/// <param name="HostTime">
/// When the first frame was captured, in 100-ns units of the host performance counter — the
/// clock <see cref="HostClock"/> reads. WASAPI reports this per packet (the QPC position).
/// </param>
/// <param name="IsSilent">The device flagged the packet as silence; treat every frame as zero.</param>
/// <param name="IsDiscontinuity">The device dropped audio before this packet.</param>
public readonly record struct RawAudioPacket(
    ReadOnlyMemory<byte> Data,
    int Frames,
    PcmFormat Format,
    long HostTime,
    bool IsSilent,
    bool IsDiscontinuity);

/// <summary>What a loopback stream captures.</summary>
public enum LoopbackScope
{
    /// <summary>
    /// Only the meeting app and its child processes (WASAPI process loopback,
    /// <c>PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE</c>). Windows build 20348 and later.
    /// </summary>
    ProcessTree,

    /// <summary>Everything the default output device plays. The fallback on older Windows.</summary>
    WholeSystem,
}

/// <summary>One way to open a loopback stream. The platform-neutral planner decides which to try.</summary>
/// <param name="Scope">Process tree or whole system.</param>
/// <param name="ProcessId">The root of the process tree to capture; ignored for <see cref="LoopbackScope.WholeSystem"/>.</param>
/// <param name="Format">The format to ask the audio engine for. Packets arrive in exactly this format.</param>
public sealed record LoopbackRequest(LoopbackScope Scope, int ProcessId, PcmFormat Format);

/// <summary>An open loopback capture session.</summary>
public interface ILoopbackSession : IAsyncDisposable
{
    /// <summary>What was opened.</summary>
    LoopbackRequest Request { get; }

    /// <summary>
    /// Yields packets until <paramref name="stopRequested"/> is cancelled, then drains what was
    /// already captured and ends normally. Loopback delivers <b>nothing</b> while nothing plays:
    /// gaps in <see cref="RawAudioPacket.HostTime"/> are silence the caller must fill.
    /// </summary>
    IAsyncEnumerable<RawAudioPacket> ReadAsync(CancellationToken stopRequested);
}

/// <summary>Captures what an application (or the whole system) plays — the remote side of a call.</summary>
/// <remarks>
/// A binding only: it opens what it is asked to open, or throws. Choosing the scope, the format
/// and the fallback order, converting and timing the samples all happen in platform-neutral
/// code that CI can test.
/// </remarks>
public interface ILoopbackCapture
{
    /// <summary>Opens and starts a loopback stream.</summary>
    /// <exception cref="InvalidOperationException">The OS refused this request (wrapping the COM error).</exception>
    Task<ILoopbackSession> OpenAsync(LoopbackRequest request, CancellationToken cancellationToken);
}

/// <summary>The host's high-resolution clock, in 100-ns units — the scale WASAPI's QPC positions use.</summary>
public interface IHostClock
{
    /// <summary>Now, in 100-ns units.</summary>
    long Now { get; }
}

/// <inheritdoc cref="IHostClock"/>
/// <remarks>
/// <see cref="Stopwatch"/> reads <c>QueryPerformanceCounter</c> on Windows, the same counter
/// WASAPI stamps packets with, so both channels share one clock without any Win32 call here.
/// </remarks>
public sealed class HostClock : IHostClock
{
    /// <summary>The shared instance.</summary>
    public static HostClock Instance { get; } = new();

    /// <inheritdoc />
    public long Now => ToHundredNanoseconds(Stopwatch.GetTimestamp(), Stopwatch.Frequency);

    /// <summary>Converts a counter reading to 100-ns units without overflowing.</summary>
    public static long ToHundredNanoseconds(long ticks, long frequency)
    {
        var seconds = ticks / frequency;
        var remainder = ticks % frequency;
        return (seconds * 10_000_000) + (remainder * 10_000_000 / frequency);
    }
}
