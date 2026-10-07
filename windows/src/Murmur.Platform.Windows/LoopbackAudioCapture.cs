using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using Murmur.Abstractions;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wasapi.CoreAudioApi.Interfaces;
using NAudio.Wave;

namespace Murmur.Platform.Windows;

/// <summary>
/// WASAPI loopback: the meeting app's process tree (process loopback), or the whole default
/// output. A binding — which request to try, conversion, resampling and timing are decided in
/// <c>Murmur.Core.Meetings</c> (<c>LoopbackPlanner</c>, <c>SystemAudioSource</c>).
/// </summary>
/// <remarks>
/// <para>
/// <b>Why not NAudio 3.1's <c>WithProcessLoopback</c>.</b> Moving off the NAudio 2.3 pin would
/// touch the dictation microphone path that has been on real hardware, and NAudio.Core 3.x adds
/// a <c>System.Numerics.Tensors</c> dependency that the app's <c>NAudio*.dll</c> publish glob
/// would silently leave behind — the failure mode that already cost one release. NAudio 2.3
/// publicly exposes everything else needed (<see cref="AudioClient"/> over an
/// <see cref="IAudioClient"/>, and <see cref="AudioCaptureClient.GetBuffer(out int, out AudioClientBufferFlags, out long, out long)"/>
/// with the QPC position), so the only new interop is one call:
/// <c>ActivateAudioInterfaceAsync</c> with <c>AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK</c>.
/// </para>
/// <para>
/// <b>The format is ours to choose.</b> A process-loopback client has no mix format
/// (<c>GetMixFormat</c> returns <c>E_NOTIMPL</c>); the stream is initialised with the requested
/// format and <c>AUTOCONVERTPCM</c>. Packets carry the QPC time of their first frame, and the
/// <c>SILENT</c> flag is passed through rather than trusting the buffer.
/// </para>
/// </remarks>
public sealed class LoopbackAudioCapture : ILoopbackCapture
{
    /// <summary><c>VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK</c>.</summary>
    private const string ProcessLoopbackDevice = "VAD\\Process_Loopback";

    private static readonly Guid IidAudioClient = new("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");

    /// <inheritdoc />
    public async Task<ILoopbackSession> OpenAsync(LoopbackRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        AudioClient client;
        try
        {
            client = request.Scope == LoopbackScope.ProcessTree
                ? new AudioClient(await ActivateProcessLoopbackAsync(request.ProcessId, cancellationToken).ConfigureAwait(false))
                : DefaultRenderClient();
        }
        catch (COMException e)
        {
            throw new InvalidOperationException($"Loopback activation failed (0x{e.HResult:X8}).", e);
        }

        try
        {
            client.Initialize(
                AudioClientShareMode.Shared,
                AudioClientStreamFlags.Loopback | AudioClientStreamFlags.EventCallback
                    | AudioClientStreamFlags.AutoConvertPcm | AudioClientStreamFlags.SrcDefaultQuality,
                BufferDuration,
                0,
                ToWaveFormat(request.Format),
                Guid.Empty);
            return new Session(client, request);
        }
        catch (Exception e) when (e is COMException or ArgumentException)
        {
            client.Dispose();
            throw new InvalidOperationException($"Loopback initialisation failed (0x{e.HResult:X8}).", e);
        }
    }

    /// <summary>
    /// Activates and initialises process loopback for this process, then releases it. Used by
    /// <c>--selftest</c>: proves the interop declarations match the OS without recording anything.
    /// </summary>
    public static string Probe()
    {
        var request = new LoopbackRequest(LoopbackScope.ProcessTree, Environment.ProcessId, PcmFormat.SpeechFloat);
        var stream = new LoopbackAudioCapture().OpenAsync(request, CancellationToken.None).GetAwaiter().GetResult();
        stream.DisposeAsync().AsTask().GetAwaiter().GetResult();
        return $"process loopback activates (build {Environment.OSVersion.Version.Build})";
    }

    /// <summary>200 ms of engine buffer, in 100-ns units.</summary>
    private const long BufferDuration = 2_000_000;

    private static AudioClient DefaultRenderClient()
    {
        using var enumerator = new MMDeviceEnumerator();
        return enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia).AudioClient;
    }

    private static WaveFormat ToWaveFormat(PcmFormat format) => format.IsFloat
        ? WaveFormat.CreateIeeeFloatWaveFormat(format.SampleRate, format.Channels)
        : new WaveFormat(format.SampleRate, format.BitsPerSample, format.Channels);

    [System.Diagnostics.CodeAnalysis.UnconditionalSuppressMessage(
        "Trimming",
        "IL2050:COMMarshalling",
        Justification = "Built-in COM interop, as NAudio itself uses throughout; the platform layer "
                      + "is published whole beside the executable and never trimmed.")]
    private static async Task<IAudioClient> ActivateProcessLoopbackAsync(int processId, CancellationToken cancellationToken)
    {
        var parameters = new ActivationParameters
        {
            ActivationType = 1,              // AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK
            TargetProcessId = (uint)processId,
            ProcessLoopbackMode = 0,         // PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE
        };

        var blob = Marshal.AllocHGlobal(Marshal.SizeOf<ActivationParameters>());
        var variant = Marshal.AllocHGlobal(Marshal.SizeOf<BlobVariant>());
        try
        {
            Marshal.StructureToPtr(parameters, blob, false);
            Marshal.StructureToPtr(new BlobVariant
            {
                VariantType = 65,            // VT_BLOB
                Size = (uint)Marshal.SizeOf<ActivationParameters>(),
                Data = blob,
            }, variant, false);

            var handler = new CompletionHandler();
            ActivateAudioInterfaceAsync(ProcessLoopbackDevice, IidAudioClient, variant, handler, out _);
            return await handler.Result.WaitAsync(TimeSpan.FromSeconds(5), cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            Marshal.FreeHGlobal(variant);
            Marshal.FreeHGlobal(blob);
        }
    }

    [DllImport("Mmdevapi.dll", ExactSpelling = true, PreserveSig = false)]
    private static extern void ActivateAudioInterfaceAsync(
        [MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
        [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
        IntPtr activationParams,
        IActivateAudioInterfaceCompletionHandler completionHandler,
        out IActivateAudioInterfaceAsyncOperation activationOperation);

    /// <summary><c>AUDIOCLIENT_ACTIVATION_PARAMS</c> with its <c>AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS</c> member.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct ActivationParameters
    {
        public int ActivationType;
        public uint TargetProcessId;
        public int ProcessLoopbackMode;
    }

    /// <summary>A <c>PROPVARIANT</c> holding a <c>BLOB</c>: 24 bytes on x64, 16 on x86.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct BlobVariant
    {
        public ushort VariantType;
        public ushort Reserved1;
        public ushort Reserved2;
        public ushort Reserved3;
        public uint Size;
        public IntPtr Data;
    }

    /// <summary>Marks the handler free-threaded: the activation completes on an MTA worker thread.</summary>
    [ComImport]
    [Guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAgileObject;

    [ComVisible(true)]
    private sealed class CompletionHandler : IActivateAudioInterfaceCompletionHandler, IAgileObject
    {
        private readonly TaskCompletionSource<IAudioClient> _result = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Task<IAudioClient> Result => _result.Task;

        public void ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation)
        {
            try
            {
                activateOperation.GetActivateResult(out var status, out var activated);
                if (status != 0) _result.TrySetException(Marshal.GetExceptionForHR(status)
                        ?? new InvalidOperationException($"Activation failed (0x{status:X8})."));
                else if (activated is IAudioClient client) _result.TrySetResult(client);
                else _result.TrySetException(new InvalidOperationException("Activation returned no IAudioClient."));
            }
            catch (COMException e)
            {
                _result.TrySetException(e);
            }
        }
    }

    /// <summary>One started session: a capture thread pumping packets into a channel.</summary>
    private sealed class Session : ILoopbackSession
    {
        private readonly AudioClient _client;
        private readonly Channel<RawAudioPacket> _packets = Channel.CreateBounded<RawAudioPacket>(
            new BoundedChannelOptions(1024)
            {
                FullMode = BoundedChannelFullMode.DropOldest,
                SingleReader = true,
                SingleWriter = true,
            });
        private readonly EventWaitHandle _ready = new(false, EventResetMode.AutoReset);
        private readonly Thread _thread;
        private volatile bool _stopping;
        private int _disposed;

        public Session(AudioClient client, LoopbackRequest request)
        {
            _client = client;
            Request = request;
            _client.SetEventHandle(_ready.SafeWaitHandle.DangerousGetHandle());
            _thread = new Thread(Pump) { IsBackground = true, Name = "Fluence loopback" };
            _client.Start();
            _thread.Start();
        }

        public LoopbackRequest Request { get; }

        public async IAsyncEnumerable<RawAudioPacket> ReadAsync([EnumeratorCancellation] CancellationToken stopRequested)
        {
            using var registration = stopRequested.Register(() =>
            {
                _stopping = true;
                _ready.Set();
            });

            await foreach (var packet in _packets.Reader.ReadAllAsync(CancellationToken.None).ConfigureAwait(false))
            {
                yield return packet;
            }
        }

        /// <summary>
        /// Waits on the event but also polls: event-driven loopback is documented for process
        /// loopback, and polling costs nothing if a driver never signals.
        /// </summary>
        private void Pump()
        {
            Exception? failure = null;
            try
            {
                var capture = _client.AudioCaptureClient;
                var blockAlign = Request.Format.BlockAlign;
                while (true)
                {
                    _ready.WaitOne(20);
                    var stopping = _stopping;

                    // Drain everything the engine holds, including after a stop request:
                    // stopping is a request, and what was already captured is delivered.
                    while (capture.GetNextPacketSize() > 0)
                    {
                        var data = capture.GetBuffer(out var frames, out var flags, out _, out var qpc);
                        var silent = (flags & AudioClientBufferFlags.Silent) != 0;
                        var bytes = silent ? [] : new byte[frames * blockAlign];
                        if (!silent) Marshal.Copy(data, bytes, 0, bytes.Length);
                        capture.ReleaseBuffer(frames);

                        _packets.Writer.TryWrite(new RawAudioPacket(
                            bytes, frames, Request.Format, qpc, silent,
                            (flags & AudioClientBufferFlags.DataDiscontinuity) != 0));
                    }

                    if (stopping) break;
                }
            }
            catch (COMException e)
            {
                // AUDCLNT_E_DEVICE_INVALIDATED and friends: the reader sees the error after
                // draining what was captured.
                failure = e;
            }
            finally
            {
                try { _client.Stop(); } catch (COMException) { /* already gone */ }
                _packets.Writer.TryComplete(failure);
            }
        }

        public ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return ValueTask.CompletedTask;
            _stopping = true;
            _ready.Set();
            _thread.Join(TimeSpan.FromSeconds(2));
            _client.Dispose();
            _ready.Dispose();
            return ValueTask.CompletedTask;
        }
    }
}
