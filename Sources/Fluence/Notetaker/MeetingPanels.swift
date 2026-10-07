import AppKit
import SwiftUI

// The Notetaker's floating surfaces. Like the dictation HUD, every one of them is a
// non-activating panel that never becomes key: the user is in a call, typing in another
// app, and a notes tool must not steal focus. Buttons and checkboxes still take clicks.
//
// Red appears only on the lit record lamp while recording (AGENTS.md: red means
// recording; `DS.Color.recordRed`, since `DS.Color.record` is the blue accent). The
// detection card shows the same lamp unlit.

/// Base panel: floats over every Space and full-screen app, never takes focus.
@MainActor
class MeetingFloatingPanel: NSPanel {
    init<Content: View>(content: Content, styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: DS.MeetingPanel.cardWidth, height: DS.MeetingPanel.cardWidth),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        if styleMask.contains(.borderless) {
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            isMovableByWindowBackground = true
        }
        contentView = NSHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Sizes the panel to its content and parks it in the top-right corner of the screen,
    /// `below` points under the menu bar.
    func present(below offset: CGFloat = 0) {
        if let fitting = contentView?.fittingSize, fitting.width > 0 {
            setContentSize(fitting)
        }
        if !isVisible, let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(
                x: visible.maxX - frame.width - DS.MeetingPanel.screenInset,
                y: visible.maxY - frame.height - DS.MeetingPanel.screenInset - offset
            ))
        }
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }
}

// MARK: - Meeting detected

@MainActor
final class MeetingDetectionPanel: MeetingFloatingPanel {
    init(controller: MeetingController) {
        super.init(content: MeetingDetectionCard(controller: controller))
    }
}

struct MeetingDetectionCard: View {
    @Bindable var controller: MeetingController

    private var title: String {
        if case .detected(let detected) = controller.state { return detected.displayName }
        return "Réunion"
    }

    private var countdownText: String {
        if let seconds = controller.countdown {
            return "Prise de notes dans \(seconds) s, sauf si vous choisissez « Pas maintenant »."
        }
        return "Prendre des notes pour cette réunion ?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.snug) {
                Lamp(color: DS.Color.recordIdle, isLit: false)
                Silkscreen(text: "Réunion détectée")
            }
            Text(title)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)
                .lineLimit(2)
            Text(countdownText)
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
                .monospacedDigit()
            if !controller.pendingDownloads.isEmpty {
                Text("Première réunion : Fluence va télécharger ses modèles locaux depuis Hugging Face. Votre audio ne quitte jamais ce Mac.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.snug) {
                TransportKey(title: "Enregistrer", systemImage: "circle.fill") { controller.acceptDetection() }
                TransportKey(title: "Pas maintenant") { controller.dismissDetection() }
            }
            .padding(.top, DS.Space.tight)
        }
        .padding(DS.Space.roomy)
        .frame(width: DS.MeetingPanel.cardWidth, alignment: .leading)
        .background(BrushedPanel(radius: DS.Radius.window))
    }
}

// MARK: - Recording indicator

@MainActor
final class MeetingRecordingPanel: MeetingFloatingPanel {
    init(controller: MeetingController) {
        super.init(content: MeetingRecordingView(controller: controller))
    }
}

struct MeetingRecordingView: View {
    @Bindable var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.snug) {
                Lamp(color: DS.Color.recordRed, isLit: controller.isRecording)
                Silkscreen(text: "Enregistrement en cours")
                Spacer(minLength: DS.Space.tight)
                DeckWindow {
                    Readout(text: Meeting.clock(controller.elapsed))
                        .padding(.horizontal, DS.Space.snug)
                        .padding(.vertical, DS.Space.hair)
                }
            }
            // The checkbox sits on its own row: the French key titles do not fit beside it
            // in the panel's fixed width.
            Toggle(isOn: $controller.keepAudio) {
                Text("Garder l'audio")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.ink)
            }
            .toggleStyle(.checkbox)
            HStack(spacing: DS.Space.snug) {
                // French then English, ready to paste into the meeting chat: recording others
                // without telling them is an offence in France (Code pénal art. 226-1).
                TransportKey(title: "Prévenir") { NotetakerConsent.copyNotice(nil) }
                    .help("Copier l'avis de consentement (français puis anglais) à coller dans le chat de la réunion")
                TransportKey(title: "En direct") { controller.showLiveTranscript() }
                    .help("Afficher la transcription en direct")
                Spacer(minLength: 0)
                TransportKey(title: "Arrêter", systemImage: "stop.fill") { controller.stop(reason: .user) }
            }
            if let notice = controller.notice {
                Text(notice)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.base)
        .frame(width: DS.MeetingPanel.recorderWidth, alignment: .leading)
        .background(BrushedPanel(radius: DS.Radius.window))
    }
}

// MARK: - Live transcript

/// Read-only, "Vous" / "Les autres" by channel; names arrive with the final pass. Opened on
/// request and excluded from screen sharing, so a shared screen never shows it.
@MainActor
final class LiveTranscriptPanel: MeetingFloatingPanel {
    init(controller: MeetingController) {
        super.init(
            content: LiveTranscriptView(controller: controller),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel]
        )
        title = "Transcription en direct"
        sharingType = .none
        setContentSize(NSSize(width: DS.MeetingPanel.transcriptWidth, height: DS.MeetingPanel.transcriptHeight))
        contentMinSize = NSSize(width: DS.MeetingPanel.recorderWidth, height: DS.MeetingPanel.transcriptMinHeight)
    }

    override func present(below offset: CGFloat = 0) {
        if !isVisible, let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(
                x: visible.maxX - frame.width - DS.MeetingPanel.screenInset,
                y: visible.minY + DS.MeetingPanel.screenInset
            ))
        }
        orderFrontRegardless()
    }
}

struct LiveTranscriptView: View {
    @Bindable var controller: MeetingController

    var body: some View {
        DeckWindow(radius: DS.Radius.none) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.snug) {
                        if controller.liveSegments.isEmpty {
                            Text(controller.isRecording ? "À l'écoute…" : "Aucune réunion n'est en cours d'enregistrement.")
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Color.inkOnDeck)
                        }
                        ForEach(controller.liveSegments) { segment in
                            HStack(alignment: .firstTextBaseline, spacing: DS.Space.snug) {
                                Silkscreen(
                                    text: segment.source == .microphone ? "Vous" : "Les autres",
                                    color: DS.Color.inkSecondary
                                )
                                .frame(width: DS.MeetingPanel.speakerColumn, alignment: .leading)
                                Text(segment.text)
                                    .font(DS.Font.body)
                                    .foregroundStyle(DS.Color.inkOnDeck)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(segment.id)
                        }
                    }
                    .padding(DS.Space.base)
                }
                .onChange(of: controller.liveSegments.count) {
                    if let last = controller.liveSegments.last {
                        withAnimation(DS.Motion.panel) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(minWidth: DS.MeetingPanel.recorderWidth, minHeight: DS.MeetingPanel.transcriptMinHeight)
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
