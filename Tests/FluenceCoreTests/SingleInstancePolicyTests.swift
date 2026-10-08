import Foundation
import Testing

@testable import FluenceCore

/// One Fluence at a time (FLU-27).
struct SingleInstancePolicyTests {
    typealias Copy = SingleInstancePolicy.Copy
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    let running = Copy(pid: 400, launched: t0)
    let second = Copy(pid: 900, launched: t0.addingTimeInterval(3600))

    @Test("a second copy hands over to the one already running")
    func secondCopyYields() {
        let target = SingleInstancePolicy.copyToYieldTo(copies: [running, second], own: 900, isScratch: false) { _ in true }
        #expect(target == running)
    }

    @Test("the copy already running never yields to a newer one")
    func runningCopyStays() {
        #expect(SingleInstancePolicy.copyToYieldTo(copies: [running, second], own: 400, isScratch: false) { _ in true } == nil)
    }

    @Test("alone, a copy starts")
    func alone() {
        #expect(SingleInstancePolicy.copyToYieldTo(copies: [second], own: 900, isScratch: false) { _ in true } == nil)
    }

    @Test("a copy on its way out (make run) does not stop the new one")
    func quittingCopyIsIgnored() {
        #expect(SingleInstancePolicy.copyToYieldTo(copies: [running, second], own: 900, isScratch: false) { $0 != 400 } == nil)
    }

    @Test("two copies opened together: exactly one starts")
    func simultaneousLaunch() {
        let a = Copy(pid: 500, launched: Self.t0)
        let b = Copy(pid: 501, launched: Self.t0)
        let quitters = [a, b].filter {
            SingleInstancePolicy.copyToYieldTo(copies: [a, b], own: $0.pid, isScratch: false) { _ in true } != nil
        }
        #expect(quitters == [b])
    }

    @Test("a development run on a scratch folder may run beside the installed app")
    func scratchRunStarts() {
        #expect(SingleInstancePolicy.copyToYieldTo(copies: [running, second], own: 900, isScratch: true) { _ in true } == nil)
    }
}
