import Testing
import Vapor

@testable import socktainer

/// Unit tests for `ExecRoute.shouldHijack`, which decides whether exec start
/// hijacks the connection or falls back to HTTP streaming.
///
/// A stdout/stderr-only exec that asked for the upgrade used to take the
/// streaming fallback, which answers 101 but never closes the connection, so
/// Go clients reading to EOF without half-closing hung (issue #442).
@Suite("ExecRoute.shouldHijack")
struct ExecHijackDecisionTests {

    private func execConfig(attachStdin: Bool) -> ExecManager.ExecConfig {
        ExecManager.ExecConfig(
            containerId: "exec-hijack",
            cmd: ["sh", "-c", "echo hi"],
            attachStdin: attachStdin,
            attachStdout: true,
            attachStderr: true,
            tty: false,
            detach: false,
            env: [],
            user: nil,
            workingDir: nil
        )
    }

    private let upgradeHeaders = HTTPHeaders([("Connection", "Upgrade"), ("Upgrade", "tcp")])

    @Test("stdout/stderr-only exec that asks for the upgrade is hijacked")
    func outputOnlyUpgradeIsHijacked() {
        #expect(ExecRoute.shouldHijack(headers: upgradeHeaders, config: execConfig(attachStdin: false)))
    }

    @Test("exec with stdin that asks for the upgrade is hijacked")
    func stdinUpgradeIsHijacked() {
        #expect(ExecRoute.shouldHijack(headers: upgradeHeaders, config: execConfig(attachStdin: true)))
    }

    @Test("request without the upgrade headers is streamed")
    func noUpgradeIsStreamed() {
        #expect(!ExecRoute.shouldHijack(headers: HTTPHeaders(), config: execConfig(attachStdin: true)))
    }

    @Test("upgrade to a protocol other than tcp is streamed")
    func otherUpgradeIsStreamed() {
        let headers = HTTPHeaders([("Connection", "Upgrade"), ("Upgrade", "websocket")])
        #expect(!ExecRoute.shouldHijack(headers: headers, config: execConfig(attachStdin: false)))
    }
}
