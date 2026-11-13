import FluenceCore
import FluenceImport
import Foundation
import Observation
import SwiftUI

/// « Importer depuis une autre app » (FLU-144): the dictionary and snippets, dictations and
/// meetings of Wispr Flow, superwhisper and Granola, read on this Mac and written through
/// Fluence's own stores — sealed, deduplicated, the other apps' files never changed. Shown as
/// an optional onboarding step and as a sheet from Réglages › Confidentialité.
@MainActor
@Observable
final class OtherAppsImport {
    enum Phase: Equatable {
        case idle, scanning, ready, importing, done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var scans: [ImportScan] = []
    /// The ticked boxes; the plan follows them.
    var selection: Set<ImportChoice> = [] {
        didSet { replan() }
    }
    private(set) var plan = ImportPlan()
    /// What the last import added, per app, and how many dictations it left aside.
    private(set) var imported: [(app: ImportApp, summary: String)] = []
    private(set) var leftAside = 0
    private var task: Task<Void, Never>?

    var retention: HistoryRetention { Settings.shared.historyRetention }

    /// An app's files are on disk. `~/Documents` is not looked at: it would prompt.
    static var anyFound: Bool {
        let locations = ImportLocations(home: FileManager.default.homeDirectoryForCurrentUser)
        return ImportApp.allCases.contains { locations.isFound($0, includeDocuments: false) }
    }

    /// Reads every app found, off the main actor. `includeDocuments` only after a click.
    func scan(includeDocuments: Bool) {
        guard phase == .idle else { return }  // coming back to the step keeps the ticks
        phase = .scanning
        task = Task {
            let started = Date()
            let home = FileManager.default.homeDirectoryForCurrentUser
            let scans = await Task.detached(priority: .userInitiated) {
                ImportScanner.scan(ImportLocations(home: home), includeDocuments: includeDocuments)
            }.value
            guard !Task.isCancelled else { return }
            self.scans = scans
            let offered = scans.filter { $0.data != nil }.flatMap { scan in
                ImportKind.allCases.map { ImportChoice(scan.app, $0) }
            }
            selection = Set(offered.filter { $0.kind != .dictations || ImportPlanner.offersDictations(retention) })
            selection = selection.filter { plan.tally($0.app, $0.kind).toImport > 0 }
            phase = .ready
            for scan in scans {
                Log.app.info("import scan: \(scan.app.rawValue, privacy: .public) found \(scan.isFound, privacy: .public), readable \(scan.data != nil, privacy: .public), \(scan.data?.entries.count ?? 0, privacy: .public) entries, \(scan.data?.snippets.count ?? 0, privacy: .public) snippets, \(scan.data?.dictations.count ?? 0, privacy: .public) dictations, \(scan.data?.meetings.count ?? 0, privacy: .public) meetings, \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public) s")
            }
        }
    }

    /// Before anything is written, this drops the scan; once writing, the import finishes.
    func cancel() {
        guard phase == .scanning || phase == .ready else { return }
        task?.cancel()
        task = nil
        phase = .idle
    }

    var canImport: Bool { phase == .ready && !plan.isEmpty }

    /// Writes the ticked items through Fluence's stores. Nothing is written without the key.
    func run() {
        guard canImport else { return }
        do {
            _ = try Vault.masterKey()
        } catch {
            phase = .failed(Vault.isKeyLost ? Vault.keyLostMessage : "Import impossible : le trousseau n'a pas donné la clé de chiffrement.")
            Log.app.error("import: no vault key, nothing written")
            Diagnostics.error("import.vault", error)
            return
        }
        replan()  // the stores may have changed since the scan
        let plan = plan
        phase = .importing
        task = Task {
            DictionaryStore.shared.add(contentsOf: plan.entries)
            for snippet in plan.snippets { SnippetStore.shared.add(snippet) }
            RunLog.importRuns(plan.dictations.map {
                DictationRun(id: $0.dictation.id, date: $0.dictation.date, engine: $0.app.name,
                             audioSeconds: $0.dictation.seconds, processSeconds: 0, text: $0.dictation.text)
            })
            var saved = 0
            var failure: String?
            for meeting in plan.meetings {
                do {
                    try MeetingStore.shared.save(meeting)
                    saved += 1
                } catch {
                    failure = "Les réunions n'ont pas toutes pu être enregistrées : \(error.localizedDescription)"
                    Diagnostics.error("import.meeting", error)
                    break
                }
                await Task.yield()  // keeps the window drawing during a long import
            }
            imported = ImportApp.allCases.compactMap { app in
                let parts = summary(app)
                return parts.isEmpty ? nil : (app, parts.joined(separator: " · "))
            }
            leftAside = selection.filter { $0.kind == .dictations }.reduce(0) { $0 + plan.tally($1.app, .dictations).leftAside }
            Log.app.info("import done: \(plan.entries.count, privacy: .public) entries, \(plan.snippets.count, privacy: .public) snippets, \(plan.dictations.count, privacy: .public) dictations, \(saved, privacy: .public)/\(plan.meetings.count, privacy: .public) meetings, \(self.leftAside, privacy: .public) left aside")
            phase = failure.map(Phase.failed) ?? .done
        }
    }

    /// « 31 entrées · 161 dictées · 58 réunions · 9 notes », from the ticked boxes.
    private func summary(_ app: ImportApp) -> [String] {
        func count(_ kind: ImportKind) -> ImportTally {
            selection.contains(ImportChoice(app, kind)) ? plan.tally(app, kind) : ImportTally()
        }
        let meetings = count(.meetings)
        return [
            (count(.dictionary).toImport, "entrée"), (count(.dictations).toImport, "dictée"),
            (meetings.toImport - meetings.notes, "réunion"), (meetings.notes, "note"),
        ].compactMap { $0.0 > 0 ? FrenchFormat.count($0.0, $0.1) : nil }
    }

    private func replan() {
        plan = ImportPlanner.plan(
            scans.compactMap(\.data),
            selection: selection,
            retention: retention,
            now: Date(),
            existing: ImportExisting(
                entries: DictionaryStore.shared.entries,
                snippets: SnippetStore.shared.snippets,
                dictations: RunStore.shared.runs.map { ($0.id, $0.date) },
                meetings: MeetingStore.shared.summaries.map { ($0.id, $0.title, $0.startedAt) }
                    + MeetingStore.shared.meetingIDs.map { ($0, "", .distantPast) }
            ),
            userNames: [NSFullUserName()]
        )
    }
}

// MARK: - Copy

enum ImportCopy {
    static let title = "Importer depuis une autre app"
    static let symbol = "square.and.arrow.down.on.square"

    /// « de plus de 30 jours », for what the history would delete at once.
    static func age(_ retention: HistoryRetention) -> String? {
        switch retention {
        case .day: "de plus d'un\u{00A0}jour"
        case .month: "de plus de 30\u{00A0}jours"
        case .never, .forever: nil
        }
    }

    /// Behind the ⓘ (FLU-19).
    static func info(_ retention: HistoryRetention) -> String {
        var text = "Fluence lit ces apps sur ce Mac et enregistre tout comme le reste : chiffré, sauf le dictionnaire, "
            + "qui reste un fichier texte modifiable. Rien ne quitte ce Mac, les autres apps ne sont pas modifiées, "
            + "et importer une seconde fois ne crée pas de doublon."
        if let age = age(retention) {
            text += " Les dictées \(age) ne sont pas importées : l'historique les effacerait aussitôt."
        } else if !retention.persists {
            text += " Les dictées ne sont pas importées : l'historique n'est pas gardé."
        }
        return text
    }
}

// MARK: - Content (shared by the onboarding step and the sheet)

/// The apps with a checkbox per kind of data (mock-up 01), the progress, then the result
/// (mock-up 03).
struct ImportContent: View {
    @Bindable var model: OtherAppsImport

    var body: some View {
        switch model.phase {
        case .idle, .scanning:
            progress("Recherche…")
        case .importing:
            progress("Import…")
        case .ready:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.scans, id: \.app) { SourceCard(model: model, scan: $0) }
            }
        case .done:
            result
        case .failed(let message):
            Text(message).font(DS.Font.caption).foregroundStyle(DS.Color.faultText).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            SpinningArc(size: 13, lineWidth: 2)
            Text(text).font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
        }
        .padding(.top, DS.Space.snug)
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.imported, id: \.app) { line in
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(DS.Color.meterGreen)
                        .accessibilityHidden(true)
                    Text(line.app.name).font(DS.Font.bodyEmphasis).foregroundStyle(DS.Color.ink)
                    Spacer(minLength: 8)
                    Text(line.summary).font(DS.Font.label).foregroundStyle(DS.Color.inkSecondary).lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)
            }
            if model.imported.isEmpty {
                Text("Rien à ajouter : tout est déjà dans Fluence.").font(DS.Font.label).foregroundStyle(DS.Color.inkSecondary)
            }
            if model.leftAside > 0, let age = ImportCopy.age(model.retention) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .medium)).accessibilityHidden(true)
                    Text("\(FrenchFormat.count(model.leftAside, "dictée")) \(age) laissée\(model.leftAside > 1 ? "s" : "") de côté")
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .padding(.top, DS.Space.snug)
            }
            HStack(spacing: 6) {
                MetaChip(text: "Chiffré sur ce Mac", systemImage: "lock.fill")
                MetaChip(text: "Aucun doublon", systemImage: "square.on.square")
            }
            .padding(.top, DS.Space.snug)
        }
    }
}

/// One app: its name, and a checkbox per kind of data it has; greyed out when not on this Mac.
private struct SourceCard: View {
    @Bindable var model: OtherAppsImport
    let scan: ImportScan

    private var kinds: [ImportKind] {
        guard scan.data != nil else { return [] }
        return ImportKind.allCases.filter { kind in
            guard kind != .dictations || ImportPlanner.offersDictations(model.retention) else { return false }
            let tally = model.plan.tally(scan.app, kind)
            return tally.toImport + tally.leftAside + tally.duplicates > 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(scan.app.name).font(DS.Font.bodyEmphasis).foregroundStyle(scan.isFound ? DS.Color.ink : DS.Color.inkSecondary)
                Spacer(minLength: 8)
                if !scan.isFound {
                    Text("Non trouvé sur ce Mac").font(DS.Font.caption).foregroundStyle(DS.Color.silkscreen)
                } else if scan.data == nil {
                    Text("Illisible").font(DS.Font.caption).foregroundStyle(DS.Color.silkscreen)
                } else if kinds.isEmpty {
                    Text("Rien à importer").font(DS.Font.caption).foregroundStyle(DS.Color.silkscreen)
                }
            }
            .frame(height: 20)
            .padding(.bottom, kinds.isEmpty ? 0 : 4)
            ForEach(kinds, id: \.self) { kind in
                row(kind)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, kinds.isEmpty ? 8 : 10)
        .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(scan.isFound ? 1 : 0.7)
    }

    private func row(_ kind: ImportKind) -> some View {
        let choice = ImportChoice(scan.app, kind)
        let tally = model.plan.tally(scan.app, kind)
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { model.selection.contains(choice) },
                set: { if $0 { model.selection.insert(choice) } else { model.selection.remove(choice) } }
            )) {
                Text(Self.title(kind)).font(DS.Font.label).foregroundStyle(DS.Color.ink).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .disabled(tally.toImport == 0)
            Spacer(minLength: 8)
            if let note = note(kind, tally) {
                Text(note).font(DS.Font.caption).foregroundStyle(DS.Color.silkscreen).lineLimit(1)
            }
            Text("\(tally.toImport)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DS.Color.inkSecondary)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .frame(height: 22)
    }

    static func title(_ kind: ImportKind) -> String {
        switch kind {
        case .dictionary: "Dictionnaire et snippets"
        case .dictations: "Dictées"
        case .meetings: "Réunions et notes"
        }
    }

    /// One detail at most: what is left aside, the meetings / notes split, or the copies.
    private func note(_ kind: ImportKind, _ tally: ImportTally) -> String? {
        if tally.leftAside > 0, let age = ImportCopy.age(model.retention) {
            return "\(tally.leftAside) \(age), laissée\(tally.leftAside > 1 ? "s" : "") de côté"
        }
        if kind == .meetings, tally.notes > 0, tally.toImport > tally.notes {
            return FrenchFormat.count(tally.toImport - tally.notes, "réunion") + " · " + FrenchFormat.count(tally.notes, "note")
        }
        if tally.toImport == 0, tally.duplicates > 0 { return "En double" }
        return nil
    }
}

// MARK: - Réglages › Confidentialité

/// The same content in a sheet, from « Importer… ».
struct ImportSheet: View {
    @State private var model = OtherAppsImport()
    @Environment(\.dismiss) private var dismiss

    private var isDone: Bool { model.phase == .done }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack(spacing: 6) {
                Image(systemName: isDone ? "checkmark.circle.fill" : ImportCopy.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isDone ? DS.Color.meterGreen : DS.Color.accent)
                    .accessibilityHidden(true)
                Text(isDone ? "Import terminé" : ImportCopy.title).font(DS.Font.title).foregroundStyle(DS.Color.ink)
                InfoButton(text: ImportCopy.info(model.retention), subject: ImportCopy.title)
            }
            ImportContent(model: model)
            HStack {
                Spacer()
                if model.phase == .done || model.phase.isFailure {
                    PrimaryButton(title: "OK") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    CapButton(title: "Annuler", isEnabled: model.phase != .importing) {
                        model.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    PrimaryButton(title: "Importer", systemImage: "square.and.arrow.down", isEnabled: model.canImport) { model.run() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(DS.Space.wide)
        .frame(width: 520)
        // A click opened the sheet: ~/Documents/superwhisper may be read, and asked about, now.
        .task { model.scan(includeDocuments: true) }
        .onDisappear { model.cancel() }
        .interactiveDismissDisabled(model.phase == .importing)
    }
}

extension OtherAppsImport.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
