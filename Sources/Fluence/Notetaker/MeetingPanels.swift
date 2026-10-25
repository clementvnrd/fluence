import AppKit
import FluenceCore
import FluenceNotesCore
import SwiftUI

// The Notetaker's floating surfaces (FLU-12, mock-up 07): the detection card with its
// countdown ring, then — while recording — a compact pill that unfolds into a panel with
// the controls and the live transcript.
//
// Like the dictation HUD, each is a non-activating panel that never becomes key: the user
// is in a call, typing in another app, and a notes tool must not steal focus. Buttons and
// checkboxes still take clicks. Red is the meeting recording's colour and appears only here,
// on the banner and on the sidebar dot (decision 3).

/// Base panel: floats over every Space and full-screen app, never takes focus.
@MainActor
class MeetingFloatingPanel: NSPanel {
    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: DS.MeetingPanel.cardWidth, height: DS.MeetingPanel.cardWidth),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        let hosting = FirstClickHostingView(rootView: content)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = hosting
    }

    // The user is in a call and typing in another app, so focus stays there; the buttons
    // still react to the first click through `FirstClickHostingView`.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Every size change keeps the top-right corner where it was and stays on the screen.
    /// The hosting view resizes the window itself as soon as SwiftUI lays out new content
    /// (pill ↔ panel, a new transcript line), and AppKit grows it from its left edge: before
    /// this, the unfolded panel ran past the right edge of the screen and `relayout()`, which
    /// runs after, kept it there.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if isVisible, rect.size != frame.size {
            rect.origin = NSPoint(x: frame.maxX - rect.width, y: frame.maxY - rect.height)
            if let visible = (screen ?? NSScreen.main)?.visibleFrame {
                rect.origin = Self.origin(of: rect.size, at: rect.origin, inside: visible)
            }
        }
        super.setFrame(rect, display: flag)
    }

    /// The closest origin that keeps a frame of `size` inside `visible`, top-left first when
    /// it is larger than the screen.
    static func origin(of size: NSSize, at origin: NSPoint, inside visible: NSRect) -> NSPoint {
        NSPoint(
            x: max(visible.minX, min(origin.x, visible.maxX - size.width)),
            y: min(visible.maxY - size.height, max(origin.y, visible.minY))
        )
    }

    /// Sizes the panel to its content and parks it in the top-right corner of the screen.
    func present() {
        fitContent(keepingTopRight: isVisible)
        if !isVisible, let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(
                x: visible.maxX - frame.width - DS.MeetingPanel.screenInset,
                y: visible.maxY - frame.height - DS.MeetingPanel.screenInset
            ))
        }
        orderFrontRegardless()
    }

    /// The content changed size (pill ↔ panel): resize around the top-right corner, where
    /// the user's eye is.
    func relayout() {
        // After SwiftUI has laid out the new content.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.fitContent(keepingTopRight: true)
        }
    }

    private func fitContent(keepingTopRight: Bool) {
        guard let fitting = contentView?.fittingSize, fitting.width > 0 else { return }
        let old = frame
        var new = NSRect(origin: old.origin, size: fitting)
        if keepingTopRight {
            new.origin.x = old.maxX - fitting.width
            new.origin.y = old.maxY - fitting.height
        }
        setFrame(new, display: true, animate: false)
    }

    func dismiss() {
        orderOut(nil)
    }
}

/// A window that never becomes key only ever receives "first" clicks; without this the
/// first click on a key would be spent bringing the panel forward.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The floating card surface: white, rounded, hairline border, soft window shadow, with a
/// margin so the shadow is not clipped by the panel.
private struct FloatCard<Content: View>: View {
    var width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(DS.Space.roomy)
            .frame(width: width, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .fill(DS.Color.panel.opacity(0.97))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline))
                    .shadow(color: DS.Shadow.window.color, radius: DS.Shadow.window.radius, y: DS.Shadow.window.y)
            }
            .padding(DS.Space.panel)
    }
}

// MARK: - Meeting detected (step 1)

@MainActor
final class MeetingDetectionPanel: MeetingFloatingPanel {
    init(controller: MeetingController) {
        super.init(content: MeetingDetectionCard(controller: controller))
    }
}

/// FLU-34: the card asks. Nothing records until *Enregistrer* is clicked, unless the user
/// chose *Enregistrer sans clic* in Settings — then the ring counts down and the text says so.
struct MeetingDetectionCard: View {
    @Bindable var controller: MeetingController
    /// Briefly true after the consent notice was copied.
    @State private var copied = false

    private var service: String {
        if case .detected(let detected) = controller.state { return detected.displayName }
        return "Réunion"
    }

    private var detail: String {
        if let seconds = controller.countdown {
            return "Enregistrement dans \(seconds)\(FrenchFormat.space)s si vous ne répondez pas."
        }
        return "Rien n'est enregistré sans votre clic."
    }

    private var total: Int { max(1, controller.countdownTotal ?? 1) }

    var body: some View {
        FloatCard(width: DS.MeetingPanel.cardWidth) {
            HStack(alignment: .top, spacing: DS.Space.base) {
                if let seconds = controller.countdown {
                    CountdownRing(seconds: seconds, total: total)
                } else {
                    Image(systemName: "person.2.wave.2")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DS.Color.accent)
                        .frame(width: DS.MeetingPanel.countdownRing, height: DS.MeetingPanel.countdownRing)
                        .background(Circle().fill(DS.Color.selection))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Réunion détectée — \(service)")
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    if !controller.pendingDownloads.isEmpty {
                        Text("Première réunion : Fluence va télécharger ses modèles locaux depuis Hugging Face. Votre audio ne quitte jamais ce Mac.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    HStack(spacing: DS.Space.snug) {
                        PrimaryButton(title: "Enregistrer", systemImage: "record.circle", height: 28) {
                            controller.acceptDetection()
                        }
                        CapButton(title: "Pas cette fois", height: 28) { controller.dismissDetection() }
                    }
                    .padding(.top, 10)
                    consentLink.padding(.top, 8)
                }
            }
        }
    }

    /// French then English, to paste into the call's chat before recording: recording
    /// people without telling them is an offence in France (Code pénal art. 226-1).
    private var consentLink: some View {
        Button {
            NotetakerConsent.copyNotice(nil)
            copied = true
            Task {
                try? await Task.sleep(for: DS.Library.flashDuration)
                copied = false
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                Text(copied ? "Copié — collez-le dans le chat de l'appel" : "Copier l'avis pour les participants")
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NotetakerConsent.text(nil))
    }
}

private struct CountdownRing: View {
    let seconds: Int
    let total: Int

    var body: some View {
        ZStack {
            Circle().stroke(DS.Color.seam, lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(seconds) / CGFloat(total))
                .stroke(DS.Color.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: seconds)
            Text("\(seconds)")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Color.ink)
                .monospacedDigit()
        }
        .frame(width: DS.MeetingPanel.countdownRing, height: DS.MeetingPanel.countdownRing)
    }
}

// MARK: - Recording (steps 2 and 3)

@MainActor
final class MeetingRecordingPanel: MeetingFloatingPanel {
    init(controller: MeetingController) {
        super.init(content: MeetingRecordingView(controller: controller))
        // It can show the live transcript: never in a screen share or a recording.
        sharingType = .none
    }
}

struct MeetingRecordingView: View {
    @Bindable var controller: MeetingController

    var body: some View {
        Group {
            if controller.isPanelExpanded {
                RecordingPanelExpanded(controller: controller)
            } else {
                RecordingPill(controller: controller)
            }
        }
        .fixedSize()
    }
}

/// Step 2: red dot, time, level, transcript, stop.
private struct RecordingPill: View {
    @Bindable var controller: MeetingController

    var body: some View {
        HStack(spacing: 10) {
            Lamp(color: DS.Color.meetingRecord, isLit: controller.isRecording, size: 7)
            Text(FrenchFormat.clock(controller.elapsed)).font(DS.Font.counter).foregroundStyle(DS.Color.ink)
            MiniWave(isActive: controller.isRecording, level: controller.inputLevel, count: 6, maxHeight: 14)
            Rectangle().fill(DS.Color.seam).frame(width: 1, height: 18)
            Button { controller.isPanelExpanded = true } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Color.inkSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Déplier : contrôles et transcription en direct")
            Button { controller.stop(reason: .user) } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Color.meetingRecord)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(DS.Color.meetingRecord.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Arrêter la prise de notes")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: DS.MeetingPanel.pillHeight)
        .background {
            // A rounded rectangle at half the height draws as a capsule; a `Capsule` here
            // showed straight slivers at its ends in off-screen renders of the panel.
            RoundedRectangle(cornerRadius: DS.MeetingPanel.pillHeight / 2).fill(DS.Color.panel.opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: DS.MeetingPanel.pillHeight / 2).strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline))
                .shadow(color: DS.Shadow.window.color, radius: 16, y: 6)
        }
        .padding(DS.Space.panel)
    }
}

/// Step 3: the controls and the live transcript, "Vous" / "Les autres" by channel.
private struct RecordingPanelExpanded: View {
    @Bindable var controller: MeetingController

    private var lines: [TranscriptSegment] { Array(controller.liveSegments.suffix(DS.MeetingPanel.liveLines)) }

    var body: some View {
        FloatCard(width: DS.MeetingPanel.panelWidth) {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                HStack(spacing: 8) {
                    Lamp(color: DS.Color.meetingRecord, isLit: controller.isRecording, size: 7)
                    Text("Prise de notes").font(DS.Font.silkscreen).foregroundStyle(DS.Color.meetingRecord)
                    if let app = controller.appName {
                        Text("· \(app)").font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
                    }
                    Spacer()
                    Text(FrenchFormat.clock(controller.elapsed)).font(DS.Font.counterLarge).foregroundStyle(DS.Color.ink)
                    Button { controller.isPanelExpanded = false } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DS.Color.inkSecondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(DS.Color.well))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Réduire")
                }
                if let title = controller.meeting?.title, !title.isEmpty {
                    Text(title).font(DS.Font.title).foregroundStyle(DS.Color.ink).lineLimit(2)
                }
                HStack(spacing: 8) {
                    Toggle(isOn: $controller.keepAudio) {
                        Text("Garder l'audio").font(DS.Font.label).foregroundStyle(DS.Color.ink)
                    }
                    .toggleStyle(.checkbox)
                    Text("sinon effacé après transcription").font(DS.Font.caption).foregroundStyle(DS.Color.silkscreen)
                }
                HStack(spacing: DS.Space.snug) {
                    // French then English, ready to paste into the meeting chat: recording
                    // others without telling them is an offence in France (Code pénal art. 226-1).
                    CapButton(title: "Consentement", systemImage: "doc.on.clipboard", height: 28) {
                        NotetakerConsent.copyNotice(nil)
                    }
                    .help("Copier l'avis de consentement (français puis anglais) à coller dans le chat de la réunion")
                    CapButton(title: "Transcription", systemImage: "text.bubble", isEngaged: true, height: 28) {
                        controller.isPanelExpanded = false
                    }
                    .help("Masquer la transcription en direct")
                    Spacer(minLength: 0)
                    RecordPill(kind: .stopMeeting, title: "Arrêter") { controller.stop(reason: .user) }
                }
                if let notice = controller.notice {
                    Text(notice)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.meterAmber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Rectangle().fill(DS.Color.seam).frame(height: 1)
                HStack {
                    Text("Transcription en direct").font(DS.Font.silkscreen).foregroundStyle(DS.Color.silkscreen)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill").font(.system(size: 8))
                        Text("sur ce Mac").font(.system(size: 10))
                    }
                    .foregroundStyle(DS.Color.silkscreen)
                }
                VStack(alignment: .leading, spacing: 10) {
                    if lines.isEmpty {
                        Text(controller.isRecording ? "À l'écoute…" : "Aucune réunion n'est en cours d'enregistrement.")
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.inkSecondary)
                    }
                    ForEach(lines) { segment in
                        let isMe = segment.source == .microphone
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isMe ? "Vous" : "Les autres")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isMe ? DS.Tone.me : DS.Tone.neutral)
                            Text(segment.text)
                                .font(DS.Font.body)
                                .foregroundStyle(segment.isFinal || segment.id != lines.last?.id ? DS.Color.ink : DS.Color.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Live banner in the main window

/// "Réunion en cours" across the top of the main window's content (mock-up 03).
struct LiveMeetingBanner: View {
    @Bindable var controller: MeetingController
    var navigation: MainNavigation

    private var detail: String {
        var parts: [String] = []
        if let app = controller.appName { parts.append(app) }
        if let count = controller.participantCount { parts.append("\(count) participants") }
        return parts.isEmpty ? "" : "· " + parts.joined(separator: " · ")
    }

    var body: some View {
        switch controller.state {
        case .recording:
            HStack(spacing: DS.Space.base) {
                Lamp(color: DS.Color.meetingRecord, isLit: true, size: 8).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Réunion en cours").font(DS.Font.silkscreen).foregroundStyle(DS.Color.meetingRecord)
                        if !detail.isEmpty {
                            Text(detail).font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
                        }
                    }
                    Text(controller.meeting?.title ?? "Prise de notes")
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                        .lineLimit(1)
                }
                Spacer()
                MiniWave(isActive: controller.isRecording, level: controller.inputLevel, count: 9, maxHeight: 16)
                Text(FrenchFormat.clock(controller.elapsed))
                    .font(DS.Font.counterLarge)
                    .foregroundStyle(DS.Color.ink)
                    .padding(.trailing, DS.Space.tight)
                CapButton(title: "Transcription", systemImage: "text.bubble", isEngaged: controller.isPanelExpanded) {
                    if controller.isPanelExpanded {
                        controller.isPanelExpanded = false
                    } else {
                        controller.showLiveTranscript()
                    }
                }
                .help("Afficher la transcription en direct dans le panneau flottant")
                RecordPill(kind: .stopMeeting, title: "Arrêter") { controller.stop(reason: .user) }
            }
            .padding(.horizontal, DS.Space.roomy)
            .padding(.vertical, DS.Space.base)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DS.Color.panel)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Color.meetingRecord.opacity(0.25), lineWidth: 1))
                    .shadow(color: DS.Shadow.panel.color, radius: DS.Shadow.panel.radius, y: DS.Shadow.panel.y)
            )
        case .processing:
            HStack(spacing: DS.Space.base) {
                ProgressView().controlSize(.small)
                Text("Réunion terminée — transcription finale et noms des intervenants en cours…")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
                Spacer()
            }
            .padding(.horizontal, DS.Space.roomy)
            .padding(.vertical, 10)
            .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .failed(let message):
            ProblemBanner(message: message) { controller.dismissFailure() }
        case .idle, .detected:
            EmptyView()
        }
    }
}

// MARK: - Menu

/// The Notetaker items of the menu bar menu.
struct MeetingMenuItems: View {
    @Bindable var controller: MeetingController

    var body: some View {
        switch controller.state {
        case .recording:
            Button("Arrêter la prise de notes") { controller.stop(reason: .user) }
            Button("Afficher la transcription en direct") { controller.showLiveTranscript() }
        case .processing:
            Text("Traitement de la réunion…")
        case .failed(let message):
            Text(message)
            Button("Ignorer") { controller.dismissFailure() }
            Button("Prendre des notes de réunion") { controller.takeNotes() }
        case .idle, .detected:
            Button("Prendre des notes de réunion") { controller.takeNotes() }
        }
    }
}
