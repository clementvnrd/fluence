import EventKit
import FluenceCore
import SwiftUI

/// The calendar's coming calls, for "À venir" (FLU-12). In memory only, re-read when the
/// calendar changes or the page is shown.
@MainActor
@Observable
final class UpcomingMeetings {
    static let shared = UpcomingMeetings()

    private(set) var events: [UpcomingCall] = []

    /// The calendar may be read: the setting is on and access is granted.
    var isAvailable: Bool { NotetakerSettings.shared.useCalendar && CalendarContext.shared.hasAccess }

    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in UpcomingMeetings.shared.refresh() }
        }
    }

    func refresh() {
        events = CalendarContext.shared.upcomingCalls()
    }
}

struct UpcomingMeetingsView: View {
    @State private var upcoming = UpcomingMeetings.shared
    @State private var settings = NotetakerSettings.shared
    @State private var hasAccess = CalendarContext.shared.hasAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ContentTitle(
                title: "À venir",
                subtitle: "Les appels de votre calendrier sur les 7 prochains jours — ceux qui ont un lien Zoom, Teams, Meet…"
            )
            .padding(.horizontal, DS.Space.panel)
            .padding(.top, 28)
            .padding(.bottom, DS.Space.roomy)

            if !settings.useCalendar {
                EmptyState(
                    systemImage: "calendar",
                    title: "Le calendrier n'est pas utilisé",
                    detail: "Avec votre calendrier, Fluence montre ici vos prochains appels et reprend le titre et les invités dans les notes. Il est lu sur ce Mac, uniquement pour cela.",
                    actionTitle: "Utiliser mon calendrier"
                ) {
                    settings.useCalendar = true
                    refresh()
                }
            } else if !hasAccess {
                EmptyState(
                    systemImage: "calendar.badge.exclamationmark",
                    title: "Fluence n'a pas accès au calendrier",
                    detail: "macOS demande votre accord une fois. Le calendrier est lu sur ce Mac et n'est jamais envoyé ailleurs.",
                    actionTitle: Permissions.calendarUndecided ? "Autoriser l'accès au calendrier" : "Ouvrir les Réglages Système"
                ) {
                    if Permissions.calendarUndecided {
                        Task {
                            _ = await Permissions.requestCalendar()
                            refresh()
                        }
                    } else {
                        Permissions.openCalendarSettings()
                    }
                }
            } else if upcoming.events.isEmpty {
                EmptyState(
                    systemImage: "calendar",
                    title: "Aucun appel prévu",
                    detail: "Rien dans les 7 prochains jours avec un lien de visioconférence."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        let now = Date()
                        ForEach(FrenchDates.groupByDay(upcoming.events, date: \.start, now: now, calendar: FrenchDates.calendar)) { group in
                            DayHeader(text: FrenchDates.label(group.key, now: now, calendar: FrenchDates.calendar))
                            ForEach(group.items) { call in
                                UpcomingRow(call: call)
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.panel)
                    .padding(.bottom, DS.Space.roomy)
                }
            }
            Spacer(minLength: 0)
            ListFooter(text: "Fluence propose de prendre des notes quand l'appel commence") {
                EmptyView()
            }
        }
        .task { refresh() }
    }

    private func refresh() {
        hasAccess = CalendarContext.shared.hasAccess
        upcoming.refresh()
    }
}

private struct UpcomingRow: View {
    let call: UpcomingCall

    var body: some View {
        HStack(spacing: DS.Space.base) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(FrenchDates.time(call.start, calendar: FrenchDates.calendar)).font(DS.Font.counter).foregroundStyle(DS.Color.ink)
                Text(FrenchDates.time(call.end, calendar: FrenchDates.calendar)).font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
            }
            .frame(width: 48, alignment: .trailing)
            Rectangle().fill(DS.Color.accent.opacity(0.5)).frame(width: 2).clipShape(Capsule())
            VStack(alignment: .leading, spacing: 3) {
                Text(call.title).font(DS.Font.bodyEmphasis).foregroundStyle(DS.Color.ink).lineLimit(1)
                Text("\(FrenchFormat.duration(call.end.timeIntervalSince(call.start))) · \(call.service)")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            Spacer()
            if !call.attendees.isEmpty {
                AvatarStack(people: call.attendees.map { ($0, false, false) })
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Color.panel)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline))
                .shadow(color: DS.Shadow.raised.color, radius: DS.Shadow.raised.radius, y: DS.Shadow.raised.y)
        )
    }
}
