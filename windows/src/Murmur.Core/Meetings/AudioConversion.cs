using System.Buffers.Binary;
using Murmur.Abstractions;

namespace Murmur.Core.Meetings;

/// <summary>
/// Decodes raw PCM packets to mono float. Platform-neutral so the conversion the Windows
/// loopback path depends on is tested on every push rather than first run on a user's call.
/// </summary>
public static class PcmConverter
{
    /// <summary>
    /// The packet's frames as mono float in [-1, 1], channels averaged. A packet flagged silent
    /// yields <see cref="RawAudioPacket.Frames"/> zeros whatever its data holds.
    /// </summary>
    /// <exception cref="NotSupportedException">A sample layout this app never asks for.</exception>
    public static float[] ToMono(RawAudioPacket packet)
    {
        var format = packet.Format;
        if (format.Channels <= 0) throw new NotSupportedException("A PCM format needs at least one channel.");
        if (packet.IsSilent) return new float[Math.Max(0, packet.Frames)];

        var data = packet.Data.Span;
        var bytesPerSample = format.BitsPerSample / 8;
        var frames = Math.Min(packet.Frames, data.Length / format.BlockAlign);
        var mono = new float[Math.Max(0, frames)];

        for (var frame = 0; frame < frames; frame++)
        {
            var sum = 0f;
            for (var channel = 0; channel < format.Channels; channel++)
            {
                var offset = (frame * format.BlockAlign) + (channel * bytesPerSample);
                sum += Sample(data.Slice(offset, bytesPerSample), format);
            }

            mono[frame] = sum / format.Channels;
        }

        return mono;
    }

    private static float Sample(ReadOnlySpan<byte> bytes, PcmFormat format) => (format.BitsPerSample, format.IsFloat) switch
    {
        (32, true) => BinaryPrimitives.ReadSingleLittleEndian(bytes),
        (16, false) => BinaryPrimitives.ReadInt16LittleEndian(bytes) / 32768f,
        (24, false) => (((bytes[2] << 24) | (bytes[1] << 16) | (bytes[0] << 8)) >> 8) / 8388608f,
        (32, false) => BinaryPrimitives.ReadInt32LittleEndian(bytes) / 2147483648f,
        _ => throw new NotSupportedException($"Unsupported PCM layout: {format.BitsPerSample}-bit, float={format.IsFloat}."),
    };
}

/// <summary>
/// A streaming windowed-sinc resampler for mono float audio. Converting 44.1 or 48 kHz loopback
/// audio to the 16 kHz the speech models take, in managed code, is what lets the loopback path
/// ask the audio engine for the formats it is documented to accept rather than hoping it
/// resamples for us.
/// </summary>
/// <remarks>
/// <para>
/// A low-pass at 95 % of the lower Nyquist frequency, Blackman-windowed, 8 zero crossings on
/// each side; each output's weights are normalised so DC passes at exactly unity. Feeding the
/// input in any chunking gives the same output as feeding it at once.
/// </para>
/// <para>About 50 multiply-adds per output sample at 48 → 16 kHz: noise next to Parakeet.</para>
/// </remarks>
public sealed class StreamingResampler
{
    private const int ZeroCrossings = 8;

    private readonly double _step;      // input samples per output sample
    private readonly double _cutoff;    // cycles per input sample
    private readonly double _halfWidth; // kernel half-width, input samples
    private readonly List<float> _input = [];
    private long _inputBase;            // absolute index of _input[0]
    private long _outputIndex;          // absolute index of the next output sample
    private bool _flushed;

    /// <summary>Creates a resampler from <paramref name="inputRate"/> to <paramref name="outputRate"/>.</summary>
    public StreamingResampler(int inputRate, int outputRate)
    {
        if (inputRate <= 0 || outputRate <= 0) throw new ArgumentOutOfRangeException(nameof(inputRate), "Rates must be positive.");
        InputRate = inputRate;
        OutputRate = outputRate;
        _step = (double)inputRate / outputRate;
        _cutoff = 0.5 * Math.Min(1.0, (double)outputRate / inputRate) * 0.95;
        _halfWidth = ZeroCrossings / (2 * _cutoff);
    }

    /// <summary>Input rate.</summary>
    public int InputRate { get; }

    /// <summary>Output rate.</summary>
    public int OutputRate { get; }

    /// <summary>Whether this resampler passes samples through untouched.</summary>
    public bool IsPassThrough => InputRate == OutputRate;

    /// <summary>Feeds input; returns every output sample it fully determines.</summary>
    public float[] Process(ReadOnlySpan<float> samples)
    {
        if (_flushed) throw new InvalidOperationException("The resampler was flushed; create a new one.");
        if (IsPassThrough) return samples.ToArray();

        foreach (var sample in samples) _input.Add(sample);
        return Drain(final: false);
    }

    /// <summary>Emits what is still held back by the filter, as if the input ended in silence.</summary>
    public float[] Flush()
    {
        if (_flushed || IsPassThrough)
        {
            _flushed = true;
            return [];
        }

        _flushed = true;
        return Drain(final: true);
    }

    private float[] Drain(bool final)
    {
        var output = new List<float>();
        var inputEnd = _inputBase + _input.Count;   // exclusive

        while (true)
        {
            var center = _outputIndex * _step;
            if (final ? center > inputEnd - 1 : center + _halfWidth >= inputEnd) break;
            output.Add(Compute(center));
            _outputIndex++;
        }

        // Keep only what the next output can still reach.
        var keepFrom = (long)Math.Floor((_outputIndex * _step) - _halfWidth) - 1;
        var drop = (int)Math.Clamp(keepFrom - _inputBase, 0, _input.Count);
        if (drop > 0)
        {
            _input.RemoveRange(0, drop);
            _inputBase += drop;
        }

        return [.. output];
    }

    private float Compute(double center)
    {
        var first = (long)Math.Ceiling(center - _halfWidth);
        var last = (long)Math.Floor(center + _halfWidth);
        double sum = 0, weights = 0;

        for (var index = first; index <= last; index++)
        {
            var distance = index - center;
            var weight = Kernel(distance);
            weights += weight;

            var local = index - _inputBase;
            if (local >= 0 && local < _input.Count) sum += weight * _input[(int)local];
        }

        return weights > 0 ? (float)(sum / weights) : 0f;
    }

    private double Kernel(double distance)
    {
        if (Math.Abs(distance) > _halfWidth) return 0;
        var x = 2 * _cutoff * distance;
        var sinc = Math.Abs(x) < 1e-12 ? 1.0 : Math.Sin(Math.PI * x) / (Math.PI * x);
        var phase = (distance + _halfWidth) / (2 * _halfWidth);   // 0…1 across the window
        var window = 0.42 - (0.5 * Math.Cos(2 * Math.PI * phase)) + (0.08 * Math.Cos(4 * Math.PI * phase));
        return sinc * window;
    }
}
