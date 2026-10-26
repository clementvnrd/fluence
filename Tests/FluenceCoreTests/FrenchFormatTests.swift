import Foundation
import Testing

@testable import FluenceCore

private let nbsp = "\u{00A0}"

/// Paris, Monday-first weeks: the calendar the app uses, pinned.
private let paris: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
}()

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    paris.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

/// Wednesday 7 October 2026, 14:00.
private let now = date(2026, 10, 7, 14, 0)

struct FrenchFormatTests {
    @Test func secondsUseADecimalCommaAndANonBreakingSpace() {
        #expect(FrenchFormat.seconds(0.62) == "0,62\(nbsp)s")
        #expect(FrenchFormat.seconds(0.276) == "0,28\(nbsp)s")
        #expect(FrenchFormat.seconds(12) == "12,00\(nbsp)s")
        #expect(FrenchFormat.seconds(-1) == "0,00\(nbsp)s")
        #expect(FrenchFormat.seconds(.nan) == "0,00\(nbsp)s")
    }

    @Test func durationsReadLikeFrench() {
        #expect(FrenchFormat.duration(42) == "42\(nbsp)s")
        #expect(FrenchFormat.duration(42 * 60 + 10) == "42\(nbsp)min")
        #expect(FrenchFormat.duration(3600) == "1\(nbsp)h")
        #expect(FrenchFormat.duration(3600 + 5 * 60) == "1\(nbsp)h\(nbsp)05")
        #expect(FrenchFormat.duration(6 * 3600 + 12 * 60) == "6\(nbsp)h\(nbsp)12")
    }

    @Test func clocksAndTimecodes() {
        #expect(FrenchFormat.clock(767) == "12:47")
        #expect(FrenchFormat.clock(3723) == "1:02:03")
        #expect(FrenchFormat.timecode(4) == "00:00:04")
        #expect(FrenchFormat.timecode(3723) == "01:02:03")
    }

    /// A damaged imported transcript can hand the UI any number (FLU-27): none may crash it.
    @Test(arguments: [Double.nan, .infinity, -.infinity, -1e300, 1e300, .greatestFiniteMagnitude])
    func anyNumberFormatsWithoutCrashing(_ value: Double) {
        let shown = value.isFinite && value > 0 ? Double(Int32.max) : 0
        #expect(FrenchFormat.duration(value) == FrenchFormat.duration(shown))
        #expect(FrenchFormat.clock(value) == FrenchFormat.clock(shown))
        #expect(FrenchFormat.timecode(value) == FrenchFormat.timecode(shown))
    }

    @Test func countsTakeTheSingularForZeroAndOne() {
        #expect(FrenchFormat.count(0, "réunion") == "0\(nbsp)réunion")
        #expect(FrenchFormat.count(1, "réunion") == "1\(nbsp)réunion")
        #expect(FrenchFormat.count(9, "réunion") == "9\(nbsp)réunions")
        #expect(FrenchFormat.count(2, "entrée") == "2\(nbsp)entrées")
        #expect(FrenchFormat.count(3, "raccourci vocal", "raccourcis vocaux") == "3\(nbsp)raccourcis vocaux")
    }

    @Test func guillemetsHoldTheirWords() {
        #expect(FrenchFormat.quoted("Kubernetes") == "«\(nbsp)Kubernetes\(nbsp)»")
    }
}

struct FrenchDatesTests {
    @Test func dayHeadings() {
        let today = FrenchDates.dayGroup(for: date(2026, 10, 7, 9), now: now, calendar: paris)
        let yesterday = FrenchDates.dayGroup(for: date(2026, 10, 6, 23, 59), now: now, calendar: paris)
        let monday = FrenchDates.dayGroup(for: date(2026, 10, 5), now: now, calendar: paris)
        let lastYear = FrenchDates.dayGroup(for: date(2025, 3, 1), now: now, calendar: paris)
        #expect(FrenchDates.label(today, now: now, calendar: paris) == "Aujourd'hui")
        #expect(FrenchDates.label(yesterday, now: now, calendar: paris) == "Hier")
        #expect(FrenchDates.label(monday, now: now, calendar: paris) == "Lundi 5 octobre")
        #expect(FrenchDates.label(lastYear, now: now, calendar: paris) == "Samedi 1er mars 2025")
    }

    @Test func groupingByDayKeepsOrderAndMergesTheSameDay() {
        let dates = [date(2026, 10, 7, 14), date(2026, 10, 7, 10), date(2026, 10, 6, 18), date(2026, 10, 5), date(2026, 10, 5, 8)]
        let groups = FrenchDates.groupByDay(dates, date: { $0 }, now: now, calendar: paris)
        #expect(groups.map(\.key) == [.today, .yesterday, .day(paris.startOfDay(for: date(2026, 10, 5)))])
        #expect(groups.map(\.items.count) == [2, 1, 2])
    }

    @Test func weekHeadingsStartOnMonday() {
        // Monday 5 October is this week; Sunday 4 October is last week.
        #expect(FrenchDates.weekGroup(for: date(2026, 10, 5, 0, 1), now: now, calendar: paris) == .thisWeek)
        #expect(FrenchDates.weekGroup(for: date(2026, 10, 4, 23), now: now, calendar: paris) == .lastWeek)
        #expect(FrenchDates.weekGroup(for: date(2026, 9, 28, 1), now: now, calendar: paris) == .lastWeek)
        let september = FrenchDates.weekGroup(for: date(2026, 9, 27), now: now, calendar: paris)
        #expect(september == .month(year: 2026, month: 9))
        #expect(FrenchDates.label(september) == "Septembre 2026")
        #expect(FrenchDates.label(.thisWeek) == "Cette semaine")
        #expect(FrenchDates.label(.lastWeek) == "Semaine dernière")
    }

    @Test func listDatesAreRelativeAndSayFirst() {
        #expect(FrenchDates.relativeDayTime(date(2026, 10, 7, 10), now: now, calendar: paris) == "Aujourd'hui, 10:00")
        #expect(FrenchDates.relativeDayTime(date(2026, 10, 6, 16, 30), now: now, calendar: paris) == "Hier, 16:30")
        #expect(FrenchDates.relativeDayTime(date(2026, 10, 5, 14), now: now, calendar: paris) == "Lun. 5 oct., 14:00")
        #expect(FrenchDates.relativeDayTime(date(2026, 10, 1, 9, 30), now: now, calendar: paris) == "Jeu. 1er oct., 09:30")
        #expect(FrenchDates.relativeDayTime(date(2025, 3, 12, 14), now: now, calendar: paris) == "12 mars 2025, 14:00")
    }

    @Test func fullDateForTheMeetingPage() {
        #expect(FrenchDates.fullDateTime(date(2026, 10, 7, 10), calendar: paris) == "Mercredi 7 octobre 2026, 10:00")
    }
}

struct ShortcutLabelTests {
    @Test func presetsKeepTheirSymbolsAndNeverWrap() {
        #expect(ShortcutLabel.display("⌥ Espace") == "⌥\(nbsp)Espace")
        #expect(ShortcutLabel.display("⌃ ⌥") == "⌃\(nbsp)⌥")
        #expect(ShortcutLabel.display("⌘ ⇧ Espace") == "⌘\(nbsp)⇧\(nbsp)Espace")
    }

    @Test func migratedNamesAreTranslatedWithTheirSide() {
        #expect(ShortcutLabel.display("rightOption") == "⌥\(nbsp)droite")
        #expect(ShortcutLabel.display("Right Option") == "⌥\(nbsp)droite")
        #expect(ShortcutLabel.display("Left Command + Space") == "⌘\(nbsp)gauche\(nbsp)Espace")
        #expect(ShortcutLabel.display("Control+Option") == "⌃\(nbsp)⌥")
    }

    @Test func spelledForm() {
        #expect(ShortcutLabel.spelled("⌥ Espace") == "⌥\(nbsp)+\(nbsp)Espace")
    }
}

struct PersonInitialsTests {
    @Test func initials() {
        #expect(PersonInitials.of("Camille Martin") == "CM")
        #expect(PersonInitials.of("Léa Dubois") == "LD")
        #expect(PersonInitials.of("Vous") == "VO")
        #expect(PersonInitials.of("Intervenant 2") == "2")
        #expect(PersonInitials.of("jean-pierre de la Fontaine") == "JF")
        #expect(PersonInitials.of("  ") == "?")
    }

    @Test func slotsAreStableAndInRange() {
        let slot = PersonInitials.slot(for: "Camille Martin", count: 5)
        #expect(slot == PersonInitials.slot(for: "camille martin", count: 5))
        #expect((0..<5).contains(slot))
        #expect(PersonInitials.slot(for: "x", count: 0) == 0)
    }
}
