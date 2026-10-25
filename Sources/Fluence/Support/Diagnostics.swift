import FluenceCore
import Foundation

/// The errors and recoveries the diagnostic export lists (FLU-35).
///
/// `os_log` keeps `.error` for a while but drops `.info`, and nothing in it can be handed over
/// by Clement. So every place that logs an error also records its *kind* here: a fixed
/// identifier from the code (`"history.write"`), plus the error's domain and code — never its
/// message, which may hold a path or a name. `StaticString` makes the kind a literal: no
/// interpolation can put dictated text in it.
///
/// Call it next to the `Log.….error(…)` it accompanies, from any thread or actor.
enum Diagnostics {
    static func error(_ kind: StaticString, _ error: (any Error)? = nil, code: Int? = nil) {
        record(kind, .error, error, code: code)
    }

    static func recovery(_ kind: StaticString, _ error: (any Error)? = nil, code: Int? = nil) {
        record(kind, .recovery, error, code: code)
    }

    private static func record(_ kind: StaticString, _ severity: DiagnosticEvent.Severity, _ error: (any Error)?, code: Int?) {
        let nsError = error.map { $0 as NSError }
        guard let event = DiagnosticEvent(
            kind: "\(kind)",
            severity: severity,
            code: code ?? nsError?.code,
            domain: nsError?.domain,
            at: Date()
        ) else {
            assertionFailure("diagnostic kind \(kind) is not an identifier")
            return
        }
        DiagnosticsLog.shared.record(event)
    }
}

/// `diagnostics.sealed` under `AppPaths.support`: the last 200 events (`DiagnosticRing`),
/// sealed by the Vault like everything else Fluence writes, although it holds no text.
///
/// One serial queue does everything; writes are batched (at most one a second), so an error
/// that repeats on every audio buffer costs one rewrite of a few kilobytes, not hundreds.
/// The rule of the other stores holds: without a key nothing is written — the events stay in
/// memory for this session's export, never in plaintext.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    private let queue = DispatchQueue(label: "diagnostics-log", qos: .utility)
    /// Queue only.
    private var ring = DiagnosticRing()
    private var hasLoaded = false
    private var writeScheduled = false

    private var url: URL { AppPaths.support.appendingPathComponent("diagnostics.sealed") }

    private init() {}

    func record(_ event: DiagnosticEvent) {
        queue.async {
            self.ring.record(event)
            self.scheduleWrite()
        }
    }

    /// The events on disk and since launch, oldest first.
    func events() async -> [DiagnosticEvent] {
        await withCheckedContinuation { continuation in
            queue.async {
                self.loadIfNeeded()
                continuation.resume(returning: self.ring.events)
            }
        }
    }

    /// The same, waiting on the caller's thread: for the self-test, which has no run loop
    /// turning yet to await on.
    func snapshot() -> [DiagnosticEvent] {
        queue.sync {
            loadIfNeeded()
            return ring.events
        }
    }

    /// Writes now and waits for it. The self-test reads the file back right after.
    func flush() {
        queue.sync { self.write() }
    }

    // MARK: - Queue only

    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        queue.asyncAfter(deadline: .now() + 1) {
            self.writeScheduled = false
            self.write()
        }
    }

    private func write() {
        loadIfNeeded()
        // Not before the file was read: writing now would replace the events it holds.
        guard hasLoaded else { return }
        do {
            try Vault.write(try ring.encoded(), to: url)
        } catch {
            // Not recorded as an event: that would schedule this write again, forever.
            Log.app.error("diagnostics not saved: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Puts the stored events before the ones recorded since launch. Tried again later when
    /// the Keychain refuses the key, so a locked Keychain at launch costs nothing.
    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        let sealed: Data
        do {
            sealed = try Data(contentsOf: url)
        } catch {
            hasLoaded = true
            return
        }
        let stored: DiagnosticRing?
        do {
            stored = DiagnosticRing.decoded(try Vault.open(sealed))
        } catch Vault.Failure.keychain {
            return
        } catch {
            // Sealed under another key or damaged. It holds no personal data: start again.
            stored = nil
        }
        var merged = stored ?? DiagnosticRing()
        for event in ring.events { merged.record(event) }
        ring = merged
        hasLoaded = true
    }
}
