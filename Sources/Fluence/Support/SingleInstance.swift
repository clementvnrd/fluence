import AppKit
import FluenceCore

/// Applies `SingleInstancePolicy` before anything else runs (FLU-27): called from
/// `FluenceApp.init`, ahead of the delegate, the stores and the shortcuts.
@MainActor
enum SingleInstance {
    /// Quits this process when another Fluence is already running, after bringing that one
    /// forward. A copy found is watched for a second first: one on its way out (`make run`
    /// quits it and opens the new build at once) lets this one start.
    static func handOverIfRunning() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        var target: NSRunningApplication?
        for attempt in 0..<10 {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            let copy = SingleInstancePolicy.copyToYieldTo(
                copies: apps.map { .init(pid: $0.processIdentifier, launched: $0.launchDate) },
                own: own,
                isScratch: AppPaths.override != nil,
                isAlive: { kill($0, 0) == 0 || errno == EPERM }
            )
            guard let copy else { return }
            target = apps.first { $0.processIdentifier == copy.pid }
            if attempt < 9 { usleep(100_000) }
        }
        guard let target else { return }
        Log.app.info("Fluence is already running (pid \(target.processIdentifier, privacy: .public)): bringing it forward and quitting")
        bringForward(target)
        exit(0)
    }

    /// Opening the running app's bundle activates it and sends it a reopen event, which shows
    /// its main window (`applicationShouldHandleReopen`).
    private static func bringForward(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else {
            app.activate()
            return
        }
        let opened = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            opened.signal()
        }
        _ = opened.wait(timeout: .now() + 3)
    }
}
