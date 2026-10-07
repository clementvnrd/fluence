/// Folds a multi-channel input down to the one channel the speech engines take.
///
/// Taking channel 0 — what the converter did by default — loses the voice entirely on an
/// audio interface whose mic is plugged into input 2. A plain average keeps it but divides
/// it by the channel count: an 8-input interface would hand the engine a voice 18 dB down.
/// So the average is taken over the channels that are actually carrying something, judged
/// against the loudest one.
public enum Downmix {
    /// Channels quieter than this fraction of the loudest one's RMS (-40 dB) are left out.
    public static let liveFraction: Float = 0.01

    /// - Parameters:
    ///   - channels: one pointer per channel. For interleaved audio, pass the base pointer
    ///     offset by each channel index and the channel count as `stride`.
    ///   - stride: distance between consecutive frames of one channel, in samples.
    ///   - frames: frames to mix.
    ///   - output: `frames` mono samples.
    public static func mono(
        channels: [UnsafePointer<Float>],
        stride: Int,
        frames: Int,
        into output: UnsafeMutablePointer<Float>
    ) {
        guard frames > 0 else { return }
        guard channels.count > 1 else {
            if let only = channels.first {
                for frame in 0..<frames { output[frame] = only[frame * stride] }
            } else {
                output.update(repeating: 0, count: frames)
            }
            return
        }

        let levels = channels.map { channel -> Float in
            var energy: Float = 0
            for frame in 0..<frames {
                let sample = channel[frame * stride]
                energy += sample * sample
            }
            return (energy / Float(frames)).squareRoot()
        }
        let loudest = levels.max() ?? 0
        // All silent: any choice is silence, so average them all.
        let live = loudest > 0
            ? channels.indices.filter { levels[$0] >= loudest * liveFraction }
            : Array(channels.indices)

        let scale = 1 / Float(live.count)
        output.update(repeating: 0, count: frames)
        for index in live {
            let channel = channels[index]
            for frame in 0..<frames { output[frame] += channel[frame * stride] * scale }
        }
    }
}
