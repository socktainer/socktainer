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

        let result = await AppleContainerBootstrap.waitForExit(of: process, timeout: .milliseconds(200))

        #expect(result == false)
        #expect(!process.isRunning)
        // The whole point of the fix: this returns because the deadline killed the
        // process, not because the process ran out its own 30-second sleep — proving
        // the caller isn't blocked indefinitely. Judged by how the process ended rather
        // than by elapsed time, which a starved CI runner stretches past any fixed bound:
        // a `sleep` left to finish exits 0, while one ended by the deadline dies of SIGTERM.
        await waitUntilReaped(process)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGTERM)
    }

    @Test("a process that ignores SIGTERM is force-killed instead of blocking past the deadline")
    func forceKillsAProcessThatIgnoresSIGTERM() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Traps and discards SIGTERM, so only SIGKILL can end this — reproduces the gap
        // CodeRabbit's follow-up review found: terminate() alone doesn't bound the wait.
        // Creates the file named by $0 once the trap is in place.
        let trapped = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("socktainer-sigterm-trapped-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: trapped) }
        process.arguments = ["-c", "trap '' TERM; : > \"$0\"; exec sleep 30", trapped.path]
        try! process.run()
        // Until the shell runs `trap`, SIGTERM alone would end it. A loaded runner can
        // take longer than the 200 ms deadline to get there, so wait for the shell.
        while process.isRunning && !FileManager.default.fileExists(atPath: trapped.path) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let result = await AppleContainerBootstrap.waitForExit(
            of: process,
            timeout: .milliseconds(200),
            killGracePeriod: .milliseconds(200)
        )

        #expect(result == false)
        // Bounded by timeout + killGracePeriod, not the process's own 30-second sleep:
        // a `sleep` left to finish exits 0, and SIGTERM is ignored, so only the
        // deadline's SIGKILL ends it early. Judged by how it ended rather than by elapsed
        // time, which a starved CI runner stretches past any fixed bound.
        await waitUntilReaped(process)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
    }

    /// `terminationReason` and `terminationStatus` are only valid once the process has
    /// been reaped. Polls rather than calling `waitUntilExit()`, which would hold a
    /// cooperative-pool thread. Never waits past the children's own 30-second runtime.
    private func waitUntilReaped(_ process: Process) async {
        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// `ensureRunning()` issues `container system start` through whichever `container` the host
/// resolves, and it runs before `AppleContainerVersionCheck` — so on a host with more than
/// one install (Homebrew's `container` formula alongside Apple's signed `.pkg`, issue #392)
/// the start could be issued by a CLI that disagrees with the version socktainer was built
/// against, before anything reported on that pairing. `mismatchOutcome` is the guard; like
/// `Outcome` above it is tested against its inputs rather than a live service.
@Suite("AppleContainerBootstrap.mismatchOutcome")
struct AppleContainerBootstrapMismatchTests {

    @Test("a matching CLI version is cleared to start the service")
    func matchingVersionProceeds() {
        let outcome = AppleContainerBootstrap.mismatchOutcome(
            cliPath: "/usr/local/bin/container",
            cliVersion: "1.5.0",
            expectedVersion: "1.5.0"
        )
        #expect(outcome == nil)
    }

    @Test("a mismatched CLI version refuses the start and names both versions")
    func mismatchedVersionRefuses() {
        let outcome = AppleContainerBootstrap.mismatchOutcome(
            cliPath: "/opt/homebrew/bin/container",
            cliVersion: "1.3.1",
            expectedVersion: "1.5.0"
        )
        #expect(outcome == .versionMismatch(cliPath: "/opt/homebrew/bin/container", detected: "1.3.1", expected: "1.5.0"))

        let message = outcome?.message ?? ""
        #expect(message.contains("WARN"))
        #expect(message.contains("/opt/homebrew/bin/container"))
        #expect(message.contains("1.3.1"))
        #expect(message.contains("1.5.0"))
        #expect(message.contains("--no-auto-start"))
    }

    @Test("an unreadable CLI version keeps the previous behavior rather than refusing")
    func unknownVersionProceeds() {
        let outcome = AppleContainerBootstrap.mismatchOutcome(
            cliPath: "/usr/local/bin/container",
            cliVersion: nil,
            expectedVersion: "1.5.0"
        )
        #expect(outcome == nil)
    }

    @Test("the mismatch message is distinct from every other outcome message")
    func mismatchMessageIsDistinct() {
        let mismatch = AppleContainerBootstrap.Outcome.versionMismatch(
            cliPath: "/opt/homebrew/bin/container",
            detected: "1.3.1",
            expected: "1.5.0"
        )
        let messages: [String] = [
            AppleContainerBootstrap.Outcome.started.message,
            AppleContainerBootstrap.Outcome.startFailed.message,
            AppleContainerBootstrap.Outcome.startedButUnresponsive.message,
            mismatch.message,
        ]
        #expect(Set(messages).count == messages.count)
    }
}

/// `containerCLIVersion(at:)` parses whatever the binary prints, so it is exercised against
/// stand-in executables rather than a real `container` — the host running the suite may have
/// any version installed, or none.
@Suite("AppleContainerBootstrap.containerCLIVersion")
struct AppleContainerBootstrapCLIVersionTests {

    @Test("a semver is extracted from a container-style version banner")
    func extractsSemverFromBanner() async throws {
        let script = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("socktainer-fake-container-\(UUID().uuidString).sh")
        try "#!/bin/sh\necho 'container CLI version 1.4.1 (build: release, commit: 9a8917c)'\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let version = await AppleContainerBootstrap.containerCLIVersion(at: script.path)
        #expect(version == "1.4.1")
    }

    @Test("output with no version produces nil rather than a wrong answer")
    func noVersionYieldsNil() async {
        let version = await AppleContainerBootstrap.containerCLIVersion(at: "/usr/bin/true")
        #expect(version == nil)
    }

    @Test("a nonexistent executable produces nil rather than throwing")
    func nonexistentExecutableYieldsNil() async {
        let version = await AppleContainerBootstrap.containerCLIVersion(
            at: "/nonexistent/socktainer-test/container"
        )
        #expect(version == nil)
    }
}
