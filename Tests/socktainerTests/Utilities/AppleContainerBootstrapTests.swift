import Foundation
import Testing

@testable import socktainer

/// `AppleContainerBootstrap.ensureRunning()` itself needs a live Apple Container service
/// (or the lack of one) to exercise meaningfully, so — like
/// `AppleContainerVersionCheck.checkCompatibility()` — it isn't unit tested directly. What
/// is tested here is the pure decision logic pulled out of it: given the shape of what
/// happened (already running / start succeeded / start failed / start "succeeded" but the
/// service still doesn't answer), what should be printed.
@Suite("AppleContainerBootstrap.Outcome")
struct AppleContainerBootstrapOutcomeTests {

    @Test("already running produces no message")
    func alreadyRunningIsSilent() {
        #expect(AppleContainerBootstrap.Outcome.alreadyRunning.message == "")
    }

    @Test("started reports success")
    func startedReportsSuccess() {
        let message = AppleContainerBootstrap.Outcome.started.message
        #expect(message.contains("started"))
        #expect(!message.contains("WARN"))
    }

    @Test("startFailed tells the user to run the command manually")
    func startFailedTellsUserToRunManually() {
        let message = AppleContainerBootstrap.Outcome.startFailed.message
        #expect(message.contains("WARN"))
        #expect(message.contains("container system start"))
    }

    @Test("startedButUnresponsive is distinct from a clean failure")
    func startedButUnresponsiveIsDistinctMessage() {
        let message = AppleContainerBootstrap.Outcome.startedButUnresponsive.message
        #expect(message.contains("WARN"))
        #expect(message != AppleContainerBootstrap.Outcome.startFailed.message)
        #expect(message.contains("exited successfully"))
    }

    @Test("every non-silent outcome message is distinct")
    func messagesAreDistinct() {
        let messages: [String] = [
            AppleContainerBootstrap.Outcome.started.message,
            AppleContainerBootstrap.Outcome.startFailed.message,
            AppleContainerBootstrap.Outcome.startedButUnresponsive.message,
        ]
        #expect(Set(messages).count == messages.count)
    }
}

/// Regression tests for a CodeRabbit review finding on PR #374: `runContainerSystemStart()`
/// used to call `Process.waitUntilExit()` with no deadline, so a stalled `container system
/// start` would block `ensureRunning()` — and therefore socktainer's entire startup, since
/// this runs before the Vapor app comes up — forever. `waitForExit(of:timeout:)` is the
/// extracted race that fixes this; tested here against real short-lived subprocesses rather
/// than a live `container system start`, mirroring how `Outcome` above is tested against
/// its inputs directly instead of a live service.
@Suite("AppleContainerBootstrap.waitForExit")
struct AppleContainerBootstrapWaitForExitTests {

    @Test("a process that exits cleanly within the deadline reports success")
    func exitsCleanlyWithinDeadline() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try! process.run()

        let result = await AppleContainerBootstrap.waitForExit(of: process, timeout: .seconds(5))
        #expect(result == true)
    }

    @Test("a process that exits non-zero within the deadline reports failure")
    func exitsNonZeroWithinDeadline() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/false")
        try! process.run()

        let result = await AppleContainerBootstrap.waitForExit(of: process, timeout: .seconds(5))
        #expect(result == false)
    }

    @Test("a process that outlives the deadline is killed and reported as failed, not hung")
    func killsAndReportsFailureWhenDeadlineExpires() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try! process.run()

        let start = ContinuousClock.now
        let result = await AppleContainerBootstrap.waitForExit(of: process, timeout: .milliseconds(200))
        let elapsed = start.duration(to: .now)

        #expect(result == false)
        // The whole point of the fix: this returns near the (short) timeout, not after the
        // process's own 30-second runtime — proving the caller isn't blocked indefinitely.
        #expect(elapsed < .seconds(10))
        #expect(!process.isRunning)
    }

    @Test("a process that ignores SIGTERM is force-killed instead of blocking past the deadline")
    func forceKillsAProcessThatIgnoresSIGTERM() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Traps and discards SIGTERM, so only SIGKILL can end this — reproduces the gap
        // CodeRabbit's follow-up review found: terminate() alone doesn't bound the wait.
        process.arguments = ["-c", "trap '' TERM; exec sleep 30"]
        try! process.run()

        let start = ContinuousClock.now
        let result = await AppleContainerBootstrap.waitForExit(
            of: process,
            timeout: .milliseconds(200),
            killGracePeriod: .milliseconds(200)
        )
        let elapsed = start.duration(to: .now)

        #expect(result == false)
        // Bounded by timeout + killGracePeriod, not the process's own 30-second sleep.
        #expect(elapsed < .seconds(10))
        #expect(!process.isRunning)
    }
}
