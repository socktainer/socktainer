import Foundation
import Testing

@testable import socktainer

/// `POST /exec/{id}/start` hijacks the connection whenever the client asks for
/// `Connection: Upgrade` + `Upgrade: tcp`, with or without stdin. The HTTP
/// streaming fallback also answers `101 Switching Protocols`, but with an unframed
/// body it cannot end and no handle on the channel to close it, so a client that
/// never half-closes its side (e.g. nektos/act) never sees EOF and hangs after the
/// process has already exited.
@Suite("ExecRoute — start hijack decision")
struct ExecStartHijackTests {

    @Test("Upgrade: tcp hijacks an exec with stdin (docker exec -i)")
    func upgradeTCPHijacks() {
        #expect(ExecRoute.shouldHijackStart(connection: "Upgrade", upgrade: "tcp", attachStdin: true))
    }

    @Test("A stdin-less exec (nektos/act) still hijacks on Upgrade: tcp")
    func stdinLessExecHijacks() {
        #expect(ExecRoute.shouldHijackStart(connection: "Upgrade", upgrade: "tcp", attachStdin: false))
    }

    @Test("Header matching is case-insensitive and tolerates a Connection list")
    func headerMatching() {
        #expect(
            ExecRoute.shouldHijackStart(connection: "keep-alive, UPGRADE", upgrade: "TCP", attachStdin: false))
    }

    @Test(
        "Missing or non-tcp upgrade headers do not hijack",
        arguments: [
            (Optional<String>.none, Optional<String>.none),
            ("Upgrade", Optional<String>.none),
            (Optional<String>.none, "tcp"),
            ("keep-alive", "tcp"),
            ("Upgrade", "websocket"),
        ])
    func noHijackWithoutTCPUpgrade(connection: String?, upgrade: String?) {
        #expect(!ExecRoute.shouldHijackStart(connection: connection, upgrade: upgrade, attachStdin: true))
        #expect(!ExecRoute.shouldHijackStart(connection: connection, upgrade: upgrade, attachStdin: false))
    }
}
