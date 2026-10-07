using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using Murmur.Abstractions;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Murmur.Platform.Windows;

/// <summary>
/// Microphone capture through WASAPI, delivering 16 kHz mono float.
/// </summary>
/// <remarks>
/// <para>
/// WASAPI shared mode normally pins you to the engine mix format (typically 48 kHz stereo),
/// but <c>AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM</c> inserts a channel matrixer and a sample-rate
/// converter, and NAudio's <see cref="WasapiCapture"/> sets that flag unconditionally. So the
/// first attempt simply asks the OS for the format the model wants.
/// </para>
/// <para>
/// The flag is named AUTOCONVERT<b>PCM</b> and the docs do not say whether IEEE float is
/// accepted as a client format. Since this cannot be tested here, the code tries three
/// formats in order and falls back to converting in managed code. All three paths produce the
/// same thing, so callers never see the difference. The format that worked is remembered and
/// tried first next time, so a device that rejects float costs one failed
/// <c>Initialize</c> per launch rather than per key press.
/// </para>
/// <para>
/// <b>Stopping drains.</b> When the stop token fires, the device is told to stop; NAudio
/// delivers the packets it already read, raises <c>RecordingStopped</c>, the resampler's tail
/// is flushed, and only then does the sequence end. Nothing captured is discarded.
/// </para>
/// <para>
/// <b>The residual gap (R1).</b> Audio starts when the device is open: COM activation and
/// <c>IAudioClient.Initialize</c>, typically 20–100 ms after the key goes down, and far more
/// on a Bluetooth headset that must switch from A2DP to the hands-free profile. Keeping the
/// enumerator alive and remembering the format trims the avoidable part. Closing the rest
/// would mean keeping the microphone open all the time behind a ring buffer, which lights the
/// Windows microphone indicator permanently and records the room while idle — rejected.
/// </para>
/// </remarks>
public sealed class WasapiAudioCapture : IAudioCapture
{
    private const int BufferMilliseconds = 50;

    private readonly string? _deviceId;
    private readonly Lock _sync = new();
    private MMDeviceEnumerator? _enumerator;
    private int _preferredFormat;
    private WasapiCapture? _capture;

    private Channel<float[]>? _channel;
    private BufferedWaveProvider? _rawSink;
    private WdlResamplingSampleProvider? _pipeline;
    private bool _nativeTargetFormat;
    private float[] _pullBuffer = [];

    /// <summary>Captures from a specific device, or the default when null.</summary>
    /// <param name="deviceId">An <c>MMDevice.ID</c>, or null for the system default.</param>
    public WasapiAudioCapture(string? deviceId = null) => _deviceId = deviceId;

    /// <inheritdoc />
    public bool IsCapturing { get; private set; }

    /// <summary>
    /// True when the microphone appears to be muted at the OS level.
    /// </summary>
    /// <remarks>
    /// When "Let desktop apps access your microphone" is off, WASAPI does not fail — it
    /// returns a stream of digital silence. There is no documented way for an unpackaged app
    /// to query that setting, so exact-zero samples are the only available signal. Real
    /// microphones have a noise floor, so a run of *precisely* zero is a reliable tell.
    /// </remarks>
    public bool LooksLikeBlockedMicrophone { get; private set; }

    private int _consecutiveSilentChunks;

    /// <summary>
    /// Proves NAudio's WASAPI types load and the audio endpoint service answers. Used by
    /// <c>--selftest</c> on the published build, where a missing NAudio DLL used to surface
    /// only at the first key press.
    /// </summary>
    /// <returns>A short description, such as "2 active capture device(s)".</returns>
    public static string Probe()
    {
        using var enumerator = new MMDeviceEnumerator();
        var devices = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active);
        return $"{devices.Count} active capture device(s)";
    }

    /// <inheritdoc />
    public async IAsyncEnumerable<AudioChunk> CaptureAsync(
        [EnumeratorCancellation] CancellationToken stopRequested)
    {
        StartCapture();
        var channel = _channel!;

        // Stop is a request, not an abort: the device stops, the channel completes once the
        // last packet is in, and the loop below drains everything that was captured.
        using var registration = stopRequested.Register(RequestStop);

        try
        {
            await foreach (var buffer in channel.Reader.ReadAllAsync(CancellationToken.None).ConfigureAwait(false))
            {
                yield return new AudioChunk(buffer);
            }
        }
        finally
        {
            StopCapture();
        }
    }

    private void RequestStop()
    {
        WasapiCapture? capture;
        lock (_sync) capture = _capture;

        try
        {
            // Asynchronous in NAudio: the capture thread finishes its current packet and then
            // raises RecordingStopped, which completes the channel.
            if (capture is not null) capture.StopRecording();
            else _channel?.Writer.TryComplete();
        }
        catch (Exception e) when (e is COMException or InvalidOperationException)
        {
            _channel?.Writer.TryComplete();
        }
    }

    private void StartCapture()
    {
        // Kept for the app's lifetime: creating the enumerator is a COM activation on every
        // press otherwise. The default endpoint is still looked up each time, so switching
        // headsets between dictations just works.
        _enumerator ??= new MMDeviceEnumerator();
        var device = _deviceId is null
            // Communications, not Console: this follows the device the user chose as their
            // default *communication* device, which is what headset users expect.
            ? _enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications)
            : _enumerator.GetDevice(_deviceId);

        // Bounded and drop-oldest so a slow consumer can never block the capture thread.
        // Losing the oldest audio is bad; stalling the audio engine is worse.
        _channel = Channel.CreateBounded<float[]>(new BoundedChannelOptions(512)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleWriter = true,
            SingleReader = true,
        });

        _consecutiveSilentChunks = 0;
        LooksLikeBlockedMicrophone = false;

        var formats = Formats(device).ToList();
        var order = Enumerable.Range(0, formats.Count)
            .OrderBy(i => i == _preferredFormat ? -1 : i);

        foreach (var index in order)
        {
            var attempt = formats[index];
            var capture = new WasapiCapture(device, useEventSync: true, BufferMilliseconds)
            {
                ShareMode = AudioClientShareMode.Shared,
            };

            try
            {
                capture.WaveFormat = attempt;

                // Decided before StartRecording, so the first callback already knows which
                // path it is on.
                _nativeTargetFormat =
                    attempt.SampleRate == AudioChunk.SampleRate &&
                    attempt.Channels == 1 &&
                    attempt.Encoding == WaveFormatEncoding.IeeeFloat;
                if (!_nativeTargetFormat) BuildManagedConverter(attempt);

                capture.DataAvailable += OnDataAvailable;
                capture.RecordingStopped += OnRecordingStopped;
                lock (_sync) _capture = capture;
                capture.StartRecording();

                _preferredFormat = index;
                IsCapturing = true;
                return;
            }
            catch (Exception ex) when (ex is COMException or ArgumentException or NotSupportedException)
            {
                lock (_sync) _capture = null;
                capture.DataAvailable -= OnDataAvailable;
                capture.RecordingStopped -= OnRecordingStopped;
                capture.Dispose();
            }
        }

        throw new InvalidOperationException("Could not open the microphone in any supported format.");
    }

    /// <summary>Formats to try, best first.</summary>
    private static IEnumerable<WaveFormat> Formats(MMDevice device)
    {
        // Exactly what the model wants — the OS resamples for us if it accepts this.
        yield return WaveFormat.CreateIeeeFloatWaveFormat(AudioChunk.SampleRate, 1);

        // Right rate and channel count, integer samples. Cheap to convert.
        yield return new WaveFormat(AudioChunk.SampleRate, 16, 1);

        // Whatever the engine is already running at; we convert in managed code.
        yield return device.AudioClient.MixFormat;
    }

    private void BuildManagedConverter(WaveFormat source)
    {
        _rawSink = new BufferedWaveProvider(source)
        {
            BufferDuration = TimeSpan.FromSeconds(3),
            DiscardOnBufferOverflow = true,
        };

        ISampleProvider provider = _rawSink.ToSampleProvider();
        if (source.Channels == 2)
        {
            provider = new StereoToMonoSampleProvider(provider) { LeftVolume = 0.5f, RightVolume = 0.5f };
        }
        else if (source.Channels > 2)
        {
            provider = new DownmixSampleProvider(provider);
        }

        // WDL, not MediaFoundationResampler: pure managed, so no COM apartment concerns and
        // nothing extra to extract from a single-file bundle.
        _pipeline = new WdlResamplingSampleProvider(provider, AudioChunk.SampleRate);
        _pullBuffer = new float[AudioChunk.SampleRate / 10];
    }

    /// <summary>
    /// Runs on NAudio's dedicated capture thread — never the UI thread.
    /// </summary>
    /// <remarks>
    /// <b>The buffer is reused on every callback.</b> <c>WasapiCapture</c> allocates one array
    /// in <c>InitializeCaptureDevice</c> and hands out the same reference every time, and
    /// <c>WaveInEventArgs</c> stores it without cloning. Anything retained past the end of
    /// this method is overwritten in place by the next callback. Copy, always.
    /// </remarks>
    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded == 0) return;

        if (_nativeTargetFormat)
        {
            var count = e.BytesRecorded / sizeof(float);
            var owned = new float[count];
            MemoryMarshal.Cast<byte, float>(e.Buffer.AsSpan(0, e.BytesRecorded)).CopyTo(owned);
            Publish(owned);
            return;
        }

        _rawSink!.AddSamples(e.Buffer, 0, e.BytesRecorded);   // AddSamples copies internally
        DrainConverter();
    }

    // Drain until the resampler starves. A zero read means "no more buffered input right
    // now" — it is not end-of-stream and not an error.
    private void DrainConverter()
    {
        while (true)
        {
            var read = _pipeline!.Read(_pullBuffer, 0, _pullBuffer.Length);
            if (read == 0) return;

            var owned = new float[read];
            Array.Copy(_pullBuffer, owned, read);
            Publish(owned);
        }
    }

    private void Publish(float[] samples)
    {
        DetectBlockedMicrophone(samples);
        _channel?.Writer.TryWrite(samples);   // TryWrite never blocks
    }

    private void DetectBlockedMicrophone(float[] samples)
    {
        var allZero = true;
        foreach (var sample in samples)
        {
            if (sample != 0f) { allZero = false; break; }
        }

        // ~1.5s of exactly-zero samples. A live microphone always has a noise floor, so this
        // means the OS is feeding us silence rather than the room being quiet.
        _consecutiveSilentChunks = allZero ? _consecutiveSilentChunks + 1 : 0;
        if (_consecutiveSilentChunks > 1500 / BufferMilliseconds) LooksLikeBlockedMicrophone = true;
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        // The resampler holds back a few milliseconds of filter history. Push 20 ms of
        // silence through so the end of the last word comes out instead of staying inside.
        if (!_nativeTargetFormat && _rawSink is not null && _pipeline is not null)
        {
            try
            {
                var silence = new byte[_rawSink.WaveFormat.AverageBytesPerSecond / 50];
                _rawSink.AddSamples(silence, 0, silence.Length - (silence.Length % _rawSink.WaveFormat.BlockAlign));
                DrainConverter();
            }
            catch (Exception ex) when (ex is ArgumentException or InvalidOperationException)
            {
                // The tail is a nicety; completing the channel is not.
            }
        }

        // A non-null exception here is usually AUDCLNT_E_DEVICE_INVALIDATED — the device was
        // unplugged or reconfigured mid-capture. The engine keeps what was captured so far.
        _channel?.Writer.TryComplete(e.Exception);
        IsCapturing = false;
    }

    private void StopCapture()
    {
        WasapiCapture? capture;
        lock (_sync)
        {
            capture = _capture;
            _capture = null;
        }

        if (capture is null) return;

        capture.DataAvailable -= OnDataAvailable;
        capture.RecordingStopped -= OnRecordingStopped;
        try { capture.StopRecording(); } catch (COMException) { /* already gone */ }
        capture.Dispose();

        _channel?.Writer.TryComplete();
        IsCapturing = false;
    }

    /// <inheritdoc />
    public ValueTask DisposeAsync()
    {
        StopCapture();
        _enumerator?.Dispose();
        _enumerator = null;
        return ValueTask.CompletedTask;
    }
}

/// <summary>
/// Averages an arbitrary number of channels down to one.
/// </summary>
/// <remarks>
/// NAudio's <see cref="StereoToMonoSampleProvider"/> handles exactly two channels. USB audio
/// interfaces routinely present four or eight.
/// </remarks>
internal sealed class DownmixSampleProvider : ISampleProvider
{
    private readonly ISampleProvider _source;
    private readonly int _channels;
    private float[] _buffer = [];

    public DownmixSampleProvider(ISampleProvider source)
    {
        _source = source;
        _channels = source.WaveFormat.Channels;
        WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 1);
    }

    public WaveFormat WaveFormat { get; }

    public int Read(float[] buffer, int offset, int count)
    {
        var needed = count * _channels;
        if (_buffer.Length < needed) _buffer = new float[needed];

        var read = _source.Read(_buffer, 0, needed);
        var frames = read / _channels;

        for (var frame = 0; frame < frames; frame++)
        {
            float sum = 0;
            for (var channel = 0; channel < _channels; channel++)
            {
                sum += _buffer[(frame * _channels) + channel];
            }
            buffer[offset + frame] = sum / _channels;
        }

        return frames;
    }
}
