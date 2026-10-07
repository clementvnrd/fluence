import SwiftUI

/// The readout that floats above the Dock while you dictate: a small deck window with the
/// record lamp, a level meter and the live transcript.
///
/// Flat and opaque on purpose. The glass pill it replaced — blur, soft shadow, a blue-purple
/// gradient on the bars — was the one piece of the app that didn't look like the equipment.
struct HUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        HStack(spacing: DS.Space.base) {
            // Red means recording, and only that: lit while the mic is open.
            Lamp(color: DS.Color.record, isLit: isRecording)

            Waveform(level: controller.level, isActive: controller.state == .listening)
                .frame(width: DS.HUD.meterSize.width, height: DS.HUD.meterSize.height)

            if isError {
                Silkscreen(text: "Fault", color: DS.Color.fault)
            }

            // MARK: FLU-5 input — which mode the key is in, printed like a mode label on a
            // deck, above the readout rather than in a colour.
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                if let modeLabel {
                    Silkscreen(text: modeLabel, color: DS.Color.inkOnDeck)
                        .lineLimit(1)
                }
                Text(label)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(isError ? DS.Color.fault : DS.Color.inkOnDeck)
                    .lineLimit(modeLabel == nil ? 2 : 1)
                    // A live transcript keeps its newest words; a message keeps its start.
                    .truncationMode(isMessage ? .tail : .head)
                    .animation(DS.Motion.readout, value: controller.transcript)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // A hands-free dictation has no key to let go of: Stop is how the mouse ends it.
            // The panel takes clicks only while this key is showing, and still never focus.
            if controller.isHandsFree, isRecording {
                TransportKey(title: "Stop", systemImage: "stop.fill", isEngaged: true) {
                    controller.stopHandsFree()
                }
            }
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.base)
        .frame(width: DS.HUD.size.width, height: DS.HUD.size.height)
        .background(DS.Color.deck, in: .rect(cornerRadius: DS.Radius.window))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.window)
                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
        )
    }

    private var isRecording: Bool {
        controller.state == .starting || controller.state == .listening
    }

    private var isError: Bool {
        if case .error = controller.state { return true }
        return false
    }

    // MARK: FLU-5 input
    private var isMessage: Bool {
        switch controller.state {
        case .error, .notice: true
        default: false
        }
    }

    private var modeLabel: String? {
        guard controller.state.isActive else { return nil }
        // Short: the readout beside it is narrow, and the Stop key says how to end it.
        if controller.isCommand { return "Command" }
        return controller.isHandsFree ? "Hands-free" : nil
    }

    private var label: String {
        switch controller.state {
        case .starting where controller.isCommand,
             .listening where controller.isCommand && controller.transcript.isEmpty:
            "Say what to change…"
        case .starting: "Listening…"
        case .listening: controller.transcript.isEmpty ? "Listening…" : controller.transcript
        // Parakeet transcribes in one pass on release, so there's nothing to show until
        // it lands — say what's happening instead of leaving an empty pill.
        case .finishing: controller.transcript.isEmpty ? "Transcribing…" : controller.transcript
        case .error(let message): message
        case .notice(let message): message
        case .idle: ""
        }
    }
}

/// Level-reactive bars — instrumentation, so the meter green is allowed here. Each
/// bar gets a fixed phase offset so the group ripples rather than pumping in unison.
private struct Waveform: View {
    let level: Float
    let isActive: Bool

    private static let phases: [Double] = (0..<DS.HUD.barCount).map { index in
        // Irrational multiplier keeps the offsets from lining up into a visible period.
        (Double(index) * 0.618).truncatingRemainder(dividingBy: 1)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / DS.HUD.meterFrameRate, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: DS.HUD.barGap) {
                ForEach(0..<DS.HUD.barCount, id: \.self) { index in
                    Rectangle()
                        .fill(DS.Color.meterGreen)
                        .frame(width: DS.HUD.barWidth, height: height(for: index, at: t))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func height(for index: Int, at time: TimeInterval) -> CGFloat {
        guard isActive else { return DS.HUD.barFloor }

        let phase = Self.phases[index]
        let wave = sin(time * 6.0 + phase * .pi * 2)
        let amplitude = CGFloat(max(0.04, level))
        // Wave rides on top of the level so bars still breathe during quiet passages.
        let scaled = amplitude * (0.55 + 0.45 * CGFloat(wave))
        return DS.HUD.barFloor + max(0, scaled) * DS.HUD.barTravel
    }
}
