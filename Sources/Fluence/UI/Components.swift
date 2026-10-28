import FluenceCore
import SwiftUI

// The building blocks of the FLU-12 screens, taken from the approved mock-ups' kit
// (`MockKit.swift`) and made interactive. Every colour, size and radius comes from `DS`.

// MARK: - People

/// A round avatar with initials, tinted per person.
struct Avatar: View {
    let name: String
    var size: CGFloat = 24
    /// An unnamed speaker: a dashed outline instead of a fill.
    var dashed = false
    var isMe = false

    private var tint: Color {
        if isMe { return DS.Tone.me }
        if dashed { return DS.Tone.neutral }
        // Slot 0 is the user's blue and the last the unnamed slate; a named person takes
        // one of the tones between.
        return DS.Tone.all[1 + PersonInitials.slot(for: name, count: DS.Tone.all.count - 2)]
    }

    var body: some View {
        ZStack {
            Circle().fill(dashed ? Color.clear : tint.opacity(DS.Tone.fillOpacity))
            if dashed {
                Circle().strokeBorder(DS.Color.inkSecondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
            }
            Text(PersonInitials.of(name))
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(dashed ? DS.Color.inkSecondary : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(width: size, height: size)
    }
}

struct AvatarStack: View {
    /// (name, isMe, isUnnamed)
    let people: [(name: String, isMe: Bool, unnamed: Bool)]
    var limit = 4
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(people.prefix(limit).enumerated()), id: \.offset) { _, person in
                Avatar(name: person.name, size: size, dashed: person.unnamed, isMe: person.isMe)
                    .background(Circle().fill(DS.Color.panel).padding(-1.5))
            }
            if people.count > limit {
                Text("+\(people.count - limit)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Color.inkSecondary)
                    .frame(width: size, height: size)
                    .background(Circle().fill(DS.Color.well))
            }
        }
    }
}

// MARK: - Brand

struct AIBadge: View {
    var body: some View {
        Text("AI")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                LinearGradient(colors: DS.Gradient.aqua, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Capsule()
            )
    }
}

/// The orb, "Fluence", the AI badge and a line under it (FLU-12 decision 4: the drawn orb).
struct BrandBlock: View {
    let subtitle: String
    var isActive = false

    var body: some View {
        HStack(spacing: 10) {
            AquaOrbView(size: 28, isActive: isActive, isListening: isActive)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text("Fluence")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(DS.Color.ink)
                    AIBadge()
                }
                Text(subtitle)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Buttons

/// The pill of the main action. Idle: the Aqua gradient ("Dicter"). Stopping a dictation:
/// blue; stopping a meeting: red — the only red recording (FLU-12 decision 3).
struct RecordPill: View {
    enum Kind { case start, stopDictation, stopMeeting }

    let kind: Kind
    let title: String
    var systemImage = "mic.fill"
    var height: CGFloat = 32
    let action: () -> Void

    private var tint: Color { kind == .stopMeeting ? DS.Color.meetingRecord : DS.Color.record }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if kind == .start {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    Circle().fill(tint).frame(width: 8, height: 8)
                }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(kind == .start ? Color.white : tint)
            .padding(.horizontal, 16)
            .frame(height: height)
            .background {
                if kind == .start {
                    Capsule()
                        .fill(LinearGradient(colors: DS.Gradient.aqua, startPoint: .top, endPoint: .bottom))
                        .shadow(color: DS.Color.aquaGlow.opacity(0.35), radius: 6, x: 0, y: 2)
                } else {
                    Capsule().fill(tint.opacity(0.12))
                        .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
                }
            }
            .contentShape(Capsule())
            .keyboardFocusRing(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()  // the keyboard ring above replaces the system one (FLU-38)
        // Never squeezed by a crowded row: a clipped capsule reads as broken.
        .fixedSize()
    }
}

/// The primary action of a sheet or card: solid accent.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var height: CGFloat = 30
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(DS.Color.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .keyboardFocusRing(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A secondary button on the cap surface; `tint` for destructive ones.
struct CapButton: View {
    let title: String
    var systemImage: String?
    var tint: Color = DS.Color.ink
    var isEngaged = false
    var height: CGFloat = 30
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(DS.Font.label).lineLimit(1)
            }
            .foregroundStyle(isEngaged ? DS.Color.accent : tint)
            .padding(.horizontal, DS.Space.base)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(isEngaged ? DS.Color.selection : (isHovered ? DS.Color.hover : DS.Color.cap))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(isEngaged ? DS.Color.selectionEdge.opacity(0.5) : DS.Color.seam, lineWidth: 1)
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .keyboardFocusRing(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        // The system ring showed on the first button when a window opened (FLU-18); the
        // keyboard ring above shows only once Tab is used (FLU-38).
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// "Tout effacer…": red outline on a faint red fill.
struct DestructiveButton: View {
    let title: String
    var systemImage = "trash"
    var height: CGFloat = 28
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                Text(title).font(DS.Font.label)
            }
            .foregroundStyle(DS.Color.destructive)
            .padding(.horizontal, DS.Space.base)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Color.destructive.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Color.destructive.opacity(0.35), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .keyboardFocusRing(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A small capsule action, as on the transcription cards (Corriger, Copier).
struct ChipButton: View {
    let title: String
    var systemImage: String?
    var accent = false
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10)) }
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tint ?? (accent ? DS.Color.accent : DS.Color.ink))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((tint.map { $0.opacity(0.12) }) ?? (accent ? DS.Color.selection : DS.Color.cap), in: Capsule())
            .overlay(Capsule().strokeBorder(accent ? DS.Color.selectionEdge : DS.Color.seam, lineWidth: 0.5))
            .contentShape(Capsule())
            .keyboardFocusRing(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

// MARK: - Chips and readouts

struct CounterChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(DS.Font.counter)
            .foregroundStyle(DS.Color.inkSecondary)
            .lineLimit(1)
            .fixedSize()  // a counter never wraps (FLU-18: « 0 / 0: / 0 / 0 » in a narrow window)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(DS.Color.well, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }
}

struct StatusChip: View {
    let text: String
    var dot: Color = DS.Color.meterGreen

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(DS.Color.well, in: Capsule())
    }
}

/// The engine badge: accent on the selection tint.
struct AccentChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DS.Color.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DS.Color.selection, in: Capsule())
    }
}

/// A neutral metadata chip.
struct MetaChip: View {
    let text: String
    var systemImage: String?
    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .medium)) }
            Text(text).font(.system(size: 10, weight: .medium, design: .rounded))
        }
        .lineLimit(1)
        .fixedSize()  // a chip never wraps (FLU-18: « Chi / ffré »)
        .foregroundStyle(DS.Color.inkSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(DS.Color.well, in: Capsule())
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(DS.Color.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.Color.seam, lineWidth: 1))
    }
}

/// The well capsule with a white capsule under the selected option.
struct PillTabs<Value: Hashable>: View {
    let options: [Value]
    let title: (Value) -> String
    var systemImage: ((Value) -> String?)?
    let selection: Value?
    var small = false
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(DS.Motion.panel) { onSelect(option) }
                } label: {
                    HStack(spacing: small ? 5 : 6) {
                        if let icon = systemImage?(option) {
                            Image(systemName: icon).font(.system(size: small ? 10 : 11, weight: .medium))
                        }
                        Text(title(option)).font(small ? .system(size: 11, weight: .medium) : DS.Font.label)
                    }
                    .padding(.horizontal, small ? 11 : 14)
                    .padding(.vertical, small ? 5 : 6)
                    .foregroundStyle(isSelected ? DS.Color.ink : DS.Color.inkSecondary)
                    .background {
                        if isSelected {
                            Capsule().fill(DS.Color.panel).shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
                        }
                    }
                    .contentShape(Capsule())
                    // Inside the well, so the ring hugs the pill rather than its 3 pt outset.
                    .keyboardFocusRing(Capsule(), outset: 1)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(DS.Color.well, in: Capsule())
    }
}

/// A menu that looks like a small popup button.
struct MenuChip<Content: View>: View {
    let title: String
    var fill = false
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 6) {
                Text(title).font(DS.Font.label).foregroundStyle(DS.Color.ink).lineLimit(1)
                if fill { Spacer(minLength: 0) }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: fill ? .infinity : nil)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.Color.cap)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(DS.Color.seam, lineWidth: 1))
                    .shadow(color: DS.Shadow.pressed.color, radius: DS.Shadow.pressed.radius, y: DS.Shadow.pressed.y)
            }
            .contentShape(Rectangle())
        }
        // `.button` + plain keeps the label drawn here; `.borderlessButton` hands it to an
        // AppKit pop-up that redraws it as icon-then-title without the chip.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !fill, vertical: true)
    }
}

// MARK: - Search

/// A rounded search well; ⌘F focuses it.
struct SearchWell: View {
    @Binding var text: String
    let placeholder: String
    var showsShortcut = true

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Color.inkSecondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Color.inkSecondary)
                        .keyboardFocusRing(Circle(), outset: 2)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Effacer la recherche")
                .accessibilityLabel("Effacer la recherche")
            } else if showsShortcut {
                Text("⌘F").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(DS.Color.silkscreen)
            }
        }
        .padding(.horizontal, DS.Space.base)
        .frame(height: 32)
        .background(DS.Color.well, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(isFocused ? DS.Color.selectionEdge : DS.Color.seam, lineWidth: DS.Border.hairline)
        )
        .background {
            // ⌘F from anywhere in the window.
            if showsShortcut {
                Button("") { isFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Lists

/// The bar under a list: a count on the left, an action on the right.
struct ListFooter<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(text).font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, DS.Space.roomy + 4)
        .padding(.vertical, 8)
        .background(DS.Color.well)
        .overlay(alignment: .top) { Rectangle().fill(DS.Color.seam).frame(height: 1) }
    }
}

/// Large content-area title (Things 3 / Notes).
struct ContentTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(DS.Color.ink)
            if let subtitle {
                Text(subtitle).font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary).lineLimit(2)
            }
        }
    }
}

/// A page's title with its actions on the right. When the actions do not fit beside the
/// title, they move under it rather than being cut short (FLU-18).
struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: DS.Space.snug) {
                ContentTitle(title: title, subtitle: subtitle)
                Spacer(minLength: DS.Space.roomy)
                HStack(spacing: DS.Space.snug) { actions() }.fixedSize()
            }
            VStack(alignment: .leading, spacing: DS.Space.base) {
                ContentTitle(title: title, subtitle: subtitle)
                // Wraps instead of a fixed-size row: a row wider than the page pushed the whole page past the window's edges.
                FlowRow(spacing: DS.Space.snug) { actions() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

struct DayHeader: View {
    let text: String
    var body: some View {
        HStack {
            Silkscreen(text: text)
            Spacer()
        }
        .padding(.leading, 2)
    }
}

/// An empty list: a symbol, a line, a hint, and optionally one action.
struct EmptyState: View {
    var systemImage = "tray"
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(DS.Color.inkSecondary.opacity(0.5))
                .padding(.bottom, 2)
                .accessibilityHidden(true)
            Text(title).font(DS.Font.bodyEmphasis).foregroundStyle(DS.Color.ink)
            Text(detail)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle, let action {
                CapButton(title: actionTitle, height: 28, action: action).padding(.top, DS.Space.snug)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.panel)
    }
}

// MARK: - Settings rows

struct SectionCard<Content: View>: View {
    var highlighted = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.Color.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(highlighted ? DS.Color.selectionEdge.opacity(0.6) : DS.Color.seam, lineWidth: 1)
                    )
                    .shadow(color: DS.Shadow.raised.color, radius: DS.Shadow.raised.radius, y: DS.Shadow.raised.y)
            )
    }
}

struct SettingsRow<Control: View>: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    /// The explanation, behind an ⓘ next to the title rather than under it (FLU-19).
    var info: String?
    var iconTint: Color = DS.Color.accent
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(iconTint)
                .frame(width: 20)
                .accessibilityHidden(true)  // decoration: the title says it
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(DS.Font.label).foregroundStyle(DS.Color.ink).lineLimit(1)
                    if let info { InfoButton(text: info, subject: title) }
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(DS.Color.inkSecondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            control.fixedSize(horizontal: true, vertical: false)
                // A switch in the row is named after it (FLU-38): VoiceOver read « switch » alone.
                .environment(\.settingsRowTitle, title)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// An explanation under a row, aligned with its title.
/// An ⓘ that explains on demand: its text on hover, in a popover on click (FLU-19 —
/// explanations stay available without being printed on every page).
struct InfoButton: View {
    let text: String
    /// What it explains, for VoiceOver: « Informations : Son ».
    var subject: String?
    @State private var isShowing = false

    var body: some View {
        Button { isShowing.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Color.silkscreen)
                .contentShape(Rectangle())
                .keyboardFocusRing(Circle(), outset: 2.5)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(text)
        .accessibilityLabel(subject.map { "Informations : \($0)" } ?? "Informations")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            Text(text)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
    }
}

struct RowNote: View {
    let text: String
    var color: Color = DS.Color.inkSecondary

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(text)
                .font(DS.Font.caption)
                .foregroundStyle(color)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.leading, 46)
        .padding(.trailing, 60)
        .padding(.bottom, 12)
        .padding(.top, -2)
    }
}

struct RowDivider: View {
    var inset: CGFloat = 46
    var body: some View {
        Rectangle().fill(DS.Color.seam).frame(height: 1).padding(.leading, inset)
    }
}

/// A switch in the accent colour, label hidden (the row carries it).
struct RowToggle: View {
    @Binding var isOn: Bool
    var isEnabled = true
    /// What VoiceOver calls the switch. In a `SettingsRow` it is the row's title already.
    var label: String?

    @Environment(\.settingsRowTitle) private var rowTitle

    /// The switch is an AppKit control: its focus is read here, not from inside a label.
    @FocusState private var isFocused: Bool

    var body: some View {
        // The label is hidden on screen (the row shows it) but kept for VoiceOver.
        Toggle(label ?? rowTitle ?? "", isOn: $isOn)
            .toggleStyle(.switch)
            .tint(DS.Color.accent)
            .labelsHidden()
            .controlSize(.small)
            .focused($isFocused)
            .focusEffectDisabled()
            .keyboardFocusRing(Capsule(), isFocused: isFocused, outset: 3.5)
            .disabled(!isEnabled)
    }
}

/// "Autorisé" in green, or a warning in amber.
struct GrantBadge: View {
    let text: String
    let isOK: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isOK ? "checkmark" : "exclamationmark").font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(isOK ? DS.Color.greenText : DS.Color.amberText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((isOK ? DS.Color.meterGreen : DS.Color.meterAmber).opacity(0.12), in: Capsule())
    }
}

// MARK: - Sidebar

struct SidebarItem: View {
    let systemImage: String
    let title: String
    var count: Int?
    var isSelected = false
    /// A meeting is being recorded: the red dot (FLU-12 decision 3).
    var isLive = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? DS.Color.accent : DS.Color.inkSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(DS.Color.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if isLive {
                        Lamp(color: DS.Color.meetingRecord, isLit: true, size: 6)
                            .help("Une réunion est en cours d'enregistrement")
                            .accessibilityLabel("Enregistrement en cours")
                    }
                    if let count {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(isSelected ? DS.Color.accent : DS.Color.silkscreen)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Color.selection)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Color.well.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
            // On the row's own edge: rows are stacked too tightly for a ring outside them.
            .keyboardFocusRing(RoundedRectangle(cornerRadius: 8, style: .continuous), outset: 0)
        }
        .buttonStyle(.plain)
        // The selection highlight is the indicator; the system focus ring the first row got
        // when a window opened read as a second selection (FLU-18). The keyboard ring above
        // shows only once Tab is used (FLU-38).
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Level

/// A small waveform. With a `level` (0…1, `AudioLevel`), the bars are as tall as the input is
/// loud: flat in silence, up when someone speaks (FLU-23); a light ripple keeps them alive
/// only while there is sound. Without a level they just pulse while `isActive`. With Reduce
/// Motion there is no ripple and no 30 fps timeline: the bars follow the voice only (FLU-38).
struct MiniWave: View {
    var isActive: Bool
    var level: Float?
    var count = 7
    var maxHeight: CGFloat = 16
    var color: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive || reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(fill)
                        .frame(width: 2.5, height: height(index, t))
                }
            }
            .frame(height: maxHeight)
        }
    }

    private var fill: AnyShapeStyle {
        if let color { return AnyShapeStyle(color.opacity(isActive ? 1 : 0.3)) }
        return isActive
            ? AnyShapeStyle(LinearGradient(colors: DS.Gradient.aqua, startPoint: .top, endPoint: .bottom))
            : AnyShapeStyle(DS.Color.accent.opacity(0.22))
    }

    private func height(_ index: Int, _ time: TimeInterval) -> CGFloat {
        CGFloat(WaveBars.height(
            index: index,
            count: count,
            level: level.map(Double.init),
            isActive: isActive,
            time: time,
            maxHeight: Double(maxHeight),
            reduceMotion: reduceMotion
        ))
    }
}

// MARK: - Progress (FLU-29)

/// A download in the capsule's small icon slot: the Finder/Safari pie, an accent outline with
/// a filled wedge (Clement's choice A on the FLU-29 mock-ups).
struct DownloadPie: View {
    var fraction: Double
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().strokeBorder(DS.Color.accent, lineWidth: 1.5)
            PieWedge(fraction: min(1, max(0, fraction))).fill(DS.Color.accent).padding(3)
        }
        .frame(width: size, height: size)
        .animation(DS.Motion.readout, value: fraction)
    }
}

private struct PieWedge: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(
            center: center,
            radius: min(rect.width, rect.height) / 2,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * fraction),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// A model loading with no measurable progress (« Préparation de Parakeet… »): an accent arc
/// turning on a faint track, in the same slot and size as `DownloadPie`.
struct SpinningArc: View {
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2
    /// Screenshots draw it still.
    var isAnimated = true
    /// Reduce Motion (FLU-38): the arc stays still, the « Préparation… » text says the rest.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var turns: Bool { isAnimated && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !turns)) { timeline in
            let turn = turns ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) : 0.08
            ZStack {
                Circle().stroke(DS.Color.accent.opacity(0.2), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0.05, to: 0.33)
                    .stroke(DS.Color.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(360 * turn))
            }
            .frame(width: size, height: size)
        }
    }
}

/// A thin determinate bar on a faint accent track (downloads in Réglages and the onboarding).
struct DownloadBar: View {
    var fraction: Double
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Color.accent.opacity(0.15))
                Capsule()
                    .fill(DS.Color.accent)
                    .frame(width: max(height, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .animation(DS.Motion.readout, value: fraction)
    }
}

// MARK: - Accessibility (FLU-38)

private struct SettingsRowTitleKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The title of the `SettingsRow` a control sits in, so its switch is named after it.
    var settingsRowTitle: String? {
        get { self[SettingsRowTitleKey.self] }
        set { self[SettingsRowTitleKey.self] = newValue }
    }
}

/// Whether an item's hover-only actions (FLU-19) show without the pointer: while VoiceOver
/// runs or the keyboard moves the focus, so they can be reached at all (FLU-38).
struct HoverActionsReveal: DynamicProperty {
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @MainActor var withoutPointer: Bool {
        voiceOver || KeyboardFocusIndicator.shared.showsRing
    }
}

// MARK: - Keyboard focus (FLU-38)

/// Whether the keyboard is moving the focus right now: Tab pressed in the key window and no
/// click since (`FocusVisibility`). Watches this app's own events only, from the first view
/// that draws a focus ring on.
@MainActor
@Observable
final class KeyboardFocusIndicator {
    static let shared = KeyboardFocusIndicator()

    private var state = FocusVisibility()
    @ObservationIgnored private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    /// The focused control of the key window shows its ring. A window that just opened is not
    /// the one Tab was pressed in, so its first control shows none (FLU-18).
    var showsRing: Bool {
        state.showsRing(keyWindow: NSApp.keyWindow?.windowNumber)
    }

    private func handle(_ event: NSEvent) {
        var next = state
        if event.type == .keyDown {
            let flags = event.modifierFlags
            guard FocusVisibility.movesFocus(
                keyCode: event.keyCode,
                command: flags.contains(.command),
                control: flags.contains(.control)
            ) else { return }
            next.handle(.focusKey(window: event.windowNumber))
        } else {
            next.handle(.pointerDown)
        }
        // Assigned only on a change: every view with a ring reads it.
        if next != state { state = next }
    }
}

/// A 2 pt ring in the accent colour, outside the control, while it has the keyboard focus and
/// the keyboard is in use. Clement's choice (FLU-38): no glow, never on window open.
private struct KeyboardFocusRing<S: InsettableShape>: ViewModifier {
    let shape: S
    let outset: CGFloat
    /// Given by a control whose focus is not visible from inside it (the switch).
    let focusOverride: Bool?

    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.overlay {
            if (focusOverride ?? isFocused) && KeyboardFocusIndicator.shared.showsRing {
                shape
                    .inset(by: -outset)
                    .stroke(DS.Color.focusRing, lineWidth: DS.Focus.ringWidth)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// The keyboard focus ring, around `shape`. Apply it inside a button's label (where
    /// `isFocused` is the button's own focus) and put `.focusEffectDisabled()` on the button,
    /// so the system ring does not draw as well.
    func keyboardFocusRing<S: InsettableShape>(_ shape: S, outset: CGFloat = DS.Focus.ringOffset) -> some View {
        modifier(KeyboardFocusRing(shape: shape, outset: outset, focusOverride: nil))
    }

    /// The keyboard focus ring for a control that reads its own focus (`@FocusState`).
    func keyboardFocusRing<S: InsettableShape>(_ shape: S, isFocused: Bool, outset: CGFloat = DS.Focus.ringOffset) -> some View {
        modifier(KeyboardFocusRing(shape: shape, outset: outset, focusOverride: isFocused))
    }
}
