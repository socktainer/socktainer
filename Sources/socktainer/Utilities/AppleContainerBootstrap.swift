import ContainerAPIClient
import Foundation

/// Colima-style auto-start: if Apple Container's apiserver isn't reachable, start it via
/// a one-time `container system start` subprocess call before continuing — matching the
/// "just works" UX colima gives Docker users, instead of requiring `container system
/// start` as a separate manual step every time. This is a startup-time bootstrap, not a
/// per-request call: it doesn't reintroduce the subprocess overhead socktainer otherwise
/// avoids by linking ContainerAPIClient directly for everything else.
///
/// Runs before `AppleContainerVersionCheck.performCompatibilityCheck()` in `main.swift`,
/// and — like that check — before `LoggingSystem.bootstrap`, so it prints directly rather
/// than going through the `Logger` the rest of the app uses once it's running.
public enum AppleContainerBootstrap {

    /// One step of the bootstrap outcome. Pure and independent of how the pings/subprocess
    /// call were actually performed, so it's unit-testable without a live Apple Container
    /// service — mirrors `AppleContainerVersionCheck.compatibilityAction(for:)`.
    enum Outcome: Equatable {
        /// The service already answered the first ping; nothing to do.
        case alreadyRunning
        /// `container system start` launched and the service now answers pings.
        case started
        /// The subprocess itself failed to launch or exited non-zero.
        case startFailed
        /// The subprocess exited 0, but the service still doesn't answer pings — e.g. it's
        /// still coming up, kernel install is mid-flight, or something else went wrong that
        /// exit code 0 doesn't surface.
        case startedButUnresponsive

        /// User-facing status line for this outcome, or an empty string when there's
        /// nothing worth printing (the common case: the service was already running).
        var message: String {
            switch self {
            case .alreadyRunning:
                return ""
            case .started:
                return "[ INFO ] Apple Container service started"
            case .startFailed:
                return "[ WARN ] Could not start Apple Container service automatically — run `container system start` manually"
            case .startedButUnresponsive:
                return
                    "[ WARN ] `container system start` exited successfully but the service still isn't responding — run `container system start` manually to see why"
            }
        }
    }

    /// Pings Apple Container's service and, if it isn't reachable, starts it and reports
    /// the outcome. A no-op (silently) when the service already answers.
    public static func ensureRunning() async {
        guard !(await isReachable()) else {
            return
        }

        print("[ INFO ] Apple Container service not running — attempting to start it...")
        let outcome: Outcome
        if await runContainerSystemStart() {
            outcome = await isReachable() ? .started : .startedButUnresponsive
        } else {
            outcome = .startFailed
        }
        print(outcome.message)
    }

    /// Whether Apple Container's apiserver answers a health-check ping within 2 seconds.
    private static func isReachable() async -> Bool {
        (try? await ClientHealthCheck.ping(timeout: .seconds(2))) != nil
    }

    /// Ceiling on how long we'll wait for `container system start` before giving up and
    /// killing it. Generous, since a cold start can genuinely include a kernel download —
    /// but bounded, so a stalled subprocess can't hang socktainer's own startup forever
    /// (this runs before the Vapor app comes up, so there'd be no server to fall back on).
    private static let startTimeout: Duration = .seconds(120)

    /// Launches `container system start` and waits (bounded by `startTimeout`) for it to
    /// finish. `--enable-kernel-install` (rather than leaving Apple's default behavior,
    /// which prompts the user) is required here, not just a convenience: socktainer usually
    /// runs as a background service with no attached TTY, so an interactive prompt would
    /// hang forever waiting for input that can never arrive — defeating the point of an
    /// automatic bootstrap entirely.
    private static func runContainerSystemStart() async -> Bool {
        // Launching via an unqualified `env container ...` depends on PATH already
        // containing wherever `container` was installed. Background launch contexts
        // (e.g. launchd) often inherit a minimal PATH that doesn't — resolve the actual
        // executable instead, matching how ClientRegistryService finds the same binary.
        guard let containerCLIPath = discoverContainerCLIPath() else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: containerCLIPath)
        process.arguments = ["system", "start", "--enable-kernel-install"]
        do {
            try process.run()
        } catch {
            return false
        }

        return await Self.waitForExit(of: process, timeout: startTimeout)
    }

    /// Races a launched process's exit against `timeout`. If the deadline passes first,
    /// sends SIGTERM and gives it `killGracePeriod` to exit cleanly; a process that ignores
    /// SIGTERM (which it's free to do) is then force-killed with SIGKILL, which it isn't
    /// free to ignore — so this always returns within `timeout + killGracePeriod`, not just
    /// on cooperative subprocesses. Separated from `runContainerSystemStart()` so the race
    /// itself — the part a stalled subprocess would actually expose — is testable against
    /// any process, not just a live `container system start`.
    ///
    /// Watches exit via `terminationHandler` rather than the blocking `waitUntilExit()`:
    /// the latter parks a Swift Concurrency worker thread for as long as the child runs,
    /// and Swift's cooperative pool is small and shared with the rest of the process — under
    /// enough concurrent subprocess-waiting tests (as CI has, with fewer cores than a dev
    /// machine), that starves the pool and stalls unrelated async work process-wide, not
    /// just this function. `terminationHandler` fires from Foundation's own process-exit
    /// monitoring, so waiting for it is a true suspension with no thread held captive.
    static func waitForExit(of process: Process, timeout: Duration, killGracePeriod: Duration = .seconds(5)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    process.terminationHandler = { process in
                        continuation.resume(returning: process.terminationStatus == 0)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                guard process.isRunning else { return false }

                process.terminate()
                try? await Task.sleep(for: killGracePeriod)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }
}
