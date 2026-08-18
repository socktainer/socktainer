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

    public static func ensureRunning() async {
        guard !(await isReachable()) else {
            return
        }

        print("[ INFO ] Apple Container service not running — attempting to start it...")
        let outcome: Outcome
        if runContainerSystemStart() {
            outcome = await isReachable() ? .started : .startedButUnresponsive
        } else {
            outcome = .startFailed
        }
        print(outcome.message)
    }

    private static func isReachable() async -> Bool {
        (try? await ClientHealthCheck.ping(timeout: .seconds(2))) != nil
    }

    /// `--enable-kernel-install` (rather than leaving Apple's default behavior, which
    /// prompts the user) is required here, not just a convenience: socktainer usually runs
    /// as a background service with no attached TTY, so an interactive prompt would hang
    /// forever waiting for input that can never arrive — defeating the point of an
    /// automatic bootstrap entirely.
    @discardableResult
    private static func runContainerSystemStart() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["container", "system", "start", "--enable-kernel-install"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
