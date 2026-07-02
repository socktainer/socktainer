import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression tests for the >16 KB request-body fix on `POST /containers/create`.
///
/// `Request.body.collect()` defaults to Vapor's `1 << 14` (16 KB) cap, and
/// `defaultMaxBodySize` is consulted *only* by Vapor's registered-route body
/// collection — which socktainer's `RegexRouter` bypasses (every route is served
/// from `RegexRoutingMiddleware`, not Vapor's route responder). So a
/// container-create payload over 16 KB (e.g. the env + config of Supabase's
/// edge-runtime / storage services) used to fail with `413 Payload Too Large`
/// before the handler ever ran. The fix makes the hand-collected body honor the
/// configured `defaultMaxBodySize`, so the cap is a deliberate policy knob, not a
/// silent 16 KB default.
///
/// These run against a LIVE server (`.running`) on an ephemeral port: the
/// in-memory tester delivers an already-`collected` body, for which
/// `collect(max:)` ignores the limit, so only a real streamed body exercises the
/// cap this fix is about.
@Suite("ContainerCreateRoute — request body size")
struct ContainerCreateRouteTests {

    /// The Abort error body shape (`{"error":true,"reason":"…"}`).
    private struct ErrorBody: Content { let reason: String }

    @Test("a >16 KB create body is collected, not rejected with 413")
    func largeBodyIsAccepted() async throws {
        // Valid create JSON, padded well past 16 KB via a large label value.
        let padding = String(repeating: "A", count: 20_000)
        let payload = #"{"Image":"socktainer-nonexistent-test-image:missing","Labels":{"pad":"\#(padding)"}}"#
        #expect(payload.utf8.count > 16_384)

        try await withCreateRouteApp(maxBodySize: "64mb") { app in
            try await app.testing(method: .running(hostname: "127.0.0.1", port: 0)).test(
                .POST, "/v1.51/containers/create?name=body-size-probe",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: payload)
            ) { res async throws in
                // The body streamed in and was collected past 16 KB; the request
                // then fails only at the image-existence check. With the bug the
                // body cap (16 KB) would raise 413 before the handler ran.
                #expect(res.status == .notFound)
                let err = try res.content.decode(ErrorBody.self)
                #expect(err.reason.contains("No such image"))
            }
        }
    }

    @Test("the configured body cap is still enforced (a body over the limit is 413)")
    func bodyOverCapIsRejected() async throws {
        // Cap below the body size — the body must be rejected at collection,
        // before the handler runs. Proves the fix bounds the buffer (DoS-safe),
        // it does not make collection unbounded. A 413 here can only come from
        // honoring the 1 KB cap.
        let payload = String(repeating: "A", count: 4_096)
        try await withCreateRouteApp(maxBodySize: "1kb") { app in
            try await app.testing(method: .running(hostname: "127.0.0.1", port: 0)).test(
                .POST, "/v1.51/containers/create?name=over-cap",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: payload)
            ) { res async in
                #expect(res.status == .payloadTooLarge)
            }
        }
    }

    @Test("an empty POST body returns 400, not a crash")
    func emptyBodyIsBadRequest() async throws {
        try await withCreateRouteApp(maxBodySize: "64mb") { app in
            try await app.testing().test(.POST, "/v1.51/containers/create?name=empty") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("a malformed JSON body returns 400, not 500")
    func malformedBodyIsBadRequest() async throws {
        try await withCreateRouteApp(maxBodySize: "64mb") { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/create?name=bad",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: "{ this is not valid json")
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }
}

// MARK: - Env-var rewrite helpers

@Suite("ContainerCreateRoute — 127.0.0.1 gateway rewrite")
struct LoopbackGatewayRewriteTests {

    @Test("URL @-form connection string is rewritten")
    func atFormIsRewritten() {
        let env = ["DB=postgresql://user:pass@127.0.0.1:5432/postgres"]
        let result = ContainerCreateRoute.rewriteLoopbackToGateway(env, gatewayIP: "192.168.67.1")
        #expect(result == ["DB=postgresql://user:pass@192.168.67.1:5432/postgres"])
    }

    @Test("URL ://-form without credentials is rewritten")
    func schemeFormIsRewritten() {
        let env = ["REDIS_URL=redis://127.0.0.1:6379"]
        let result = ContainerCreateRoute.rewriteLoopbackToGateway(env, gatewayIP: "10.0.0.1")
        #expect(result == ["REDIS_URL=redis://10.0.0.1:6379"])
    }

    @Test("Bind-address var is left unchanged")
    func bindAddressUnchanged() {
        let env = ["LISTEN=127.0.0.1:8080"]
        let result = ContainerCreateRoute.rewriteLoopbackToGateway(env, gatewayIP: "192.168.67.1")
        #expect(result == env)
    }

    @Test("Multiple env vars — only URL-form rewritten")
    func multipleVarsMixed() {
        let env = [
            "DB=postgresql://user@127.0.0.1:5432/db",
            "BIND=127.0.0.1:80",
            "CACHE=redis://127.0.0.1:6379",
        ]
        let result = ContainerCreateRoute.rewriteLoopbackToGateway(env, gatewayIP: "10.1.2.3")
        #expect(result[0] == "DB=postgresql://user@10.1.2.3:5432/db")
        #expect(result[1] == "BIND=127.0.0.1:80")  // unchanged
        #expect(result[2] == "CACHE=redis://10.1.2.3:6379")
    }
}

@Suite("ContainerCreateRoute — peer hostname rewrite")
struct PeerHostnameRewriteTests {

    private let peers = ["supabase_db_supabase": "192.168.67.3", "db": "192.168.67.3"]

    @Test("@hostname:port form is rewritten")
    func atFormIsRewritten() {
        let env = ["URL=postgresql://user@supabase_db_supabase:5432/postgres"]
        let result = ContainerCreateRoute.rewritePeerHostnames(env, peers: peers)
        #expect(result == ["URL=postgresql://user@192.168.67.3:5432/postgres"])
    }

    @Test("host=hostname key-value form is rewritten")
    func hostKeyValueIsRewritten() {
        let env = ["GOTRUE_DB_DSN=host=supabase_db_supabase user=admin dbname=postgres"]
        let result = ContainerCreateRoute.rewritePeerHostnames(env, peers: peers)
        #expect(result == ["GOTRUE_DB_DSN=host=192.168.67.3 user=admin dbname=postgres"])
    }

    @Test("Unknown hostname is left unchanged")
    func unknownHostnameUnchanged() {
        let env = ["URL=postgresql://user@other_service:5432/db"]
        let result = ContainerCreateRoute.rewritePeerHostnames(env, peers: peers)
        #expect(result == env)
    }

    @Test("Short alias is also rewritten")
    func shortAliasRewritten() {
        let env = ["DB_HOST=host=db port=5432"]
        let result = ContainerCreateRoute.rewritePeerHostnames(env, peers: peers)
        #expect(result == ["DB_HOST=host=192.168.67.3 port=5432"])
    }

    @Test("Empty peers list leaves env unchanged")
    func emptyPeersNoChange() {
        let env = ["URL=postgresql://user@supabase_db_supabase:5432/db"]
        let result = ContainerCreateRoute.rewritePeerHostnames(env, peers: [:])
        #expect(result == env)
    }
}

@Suite("ContainerCreateRoute — SSH agent forwarding")
struct SSHAgentForwardingTests {

    /// Creates a real Unix domain socket at a temp path so `stat` reports S_IFSOCK.
    private func makeUnixSocket() throws -> (path: String, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Keep the path short: sun_path is limited to ~104 bytes on Darwin.
        let path = dir.appendingPathComponent("agent").path

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { src in
                raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(raw.count - 1)))
            }
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bindResult == 0)
        let cleanup = {
            close(fd)
            try? FileManager.default.removeItem(at: dir)
        }
        return (path, cleanup)
    }

    @Test("Declared SSH_AUTH_SOCK env matching the mount target triggers forwarding")
    func envDeclaredMatch() throws {
        let (socketPath, cleanup) = try makeUnixSocket()
        defer { cleanup() }

        let match = SSHAgentForwarding.detect(
            candidates: [(source: socketPath, target: "/ssh-agent")],
            containerEnv: ["FOO=bar", "SSH_AUTH_SOCK=/ssh-agent"],
            hostEnvironment: [:]
        )
        #expect(match == SSHAgentForwarding.Match(hostPath: socketPath, source: socketPath, declaredTarget: "/ssh-agent"))
    }

    @Test("A socket mount without any SSH_AUTH_SOCK declaration is not treated as an agent")
    func unrelatedSocketDoesNotMatch() throws {
        let (socketPath, cleanup) = try makeUnixSocket()
        defer { cleanup() }

        // e.g. a gpg-agent or docker.sock style mount — no SSH_AUTH_SOCK env.
        let match = SSHAgentForwarding.detect(
            candidates: [(source: socketPath, target: "/gpg-agent")],
            containerEnv: ["GPG_TTY=/dev/tty"],
            hostEnvironment: [:]
        )
        #expect(match == nil)
    }

    @Test("Declared env pointing elsewhere does not match the socket mount")
    func declaredTargetMismatch() throws {
        let (socketPath, cleanup) = try makeUnixSocket()
        defer { cleanup() }

        let match = SSHAgentForwarding.detect(
            candidates: [(source: socketPath, target: "/gpg-agent")],
            containerEnv: ["SSH_AUTH_SOCK=/somewhere-else"],
            hostEnvironment: [:]
        )
        #expect(match == nil)
    }

    @Test("A non-socket source never matches even with a declared env")
    func nonSocketSourceDoesNotMatch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let match = SSHAgentForwarding.detect(
            candidates: [(source: dir.path, target: "/ssh-agent")],
            containerEnv: ["SSH_AUTH_SOCK=/ssh-agent"],
            hostEnvironment: [:]
        )
        #expect(match == nil)
    }

    @Test("Mounting the host's own $SSH_AUTH_SOCK matches without an env declaration")
    func hostAgentSourceMatch() throws {
        let (socketPath, cleanup) = try makeUnixSocket()
        defer { cleanup() }

        let match = SSHAgentForwarding.detect(
            candidates: [(source: socketPath, target: "/ssh-agent")],
            containerEnv: [],
            hostEnvironment: ["SSH_AUTH_SOCK": socketPath]
        )
        #expect(match == SSHAgentForwarding.Match(hostPath: socketPath, source: socketPath, declaredTarget: nil))
    }

    @Test("Docker Desktop's well-known path is an alias for the host agent socket")
    func dockerDesktopCompatibilityPath() throws {
        let (socketPath, cleanup) = try makeUnixSocket()
        defer { cleanup() }

        let match = SSHAgentForwarding.detect(
            candidates: [(source: SSHAgentForwarding.dockerDesktopSocketPath, target: "/ssh-agent")],
            containerEnv: ["SSH_AUTH_SOCK=/ssh-agent"],
            hostEnvironment: ["SSH_AUTH_SOCK": socketPath]
        )
        #expect(
            match
                == SSHAgentForwarding.Match(
                    hostPath: socketPath,
                    source: SSHAgentForwarding.dockerDesktopSocketPath,
                    declaredTarget: "/ssh-agent"
                ))
    }

    @Test("Docker Desktop path without a host agent available does not match")
    func dockerDesktopPathWithoutHostAgent() {
        let match = SSHAgentForwarding.detect(
            candidates: [(source: SSHAgentForwarding.dockerDesktopSocketPath, target: "/ssh-agent")],
            containerEnv: ["SSH_AUTH_SOCK=/ssh-agent"],
            hostEnvironment: [:]
        )
        #expect(match == nil)
    }

    @Test("rewriteEnv replaces the declared target with the guest relay path")
    func rewriteEnvReplacesDeclaredTarget() {
        let rewritten = SSHAgentForwarding.rewriteEnv(
            ["FOO=bar", "SSH_AUTH_SOCK=/ssh-agent", "BAZ=qux"],
            declaredTarget: "/ssh-agent"
        )
        #expect(rewritten == ["FOO=bar", "SSH_AUTH_SOCK=\(SSHAgentForwarding.guestSocketPath)", "BAZ=qux"])
    }

    @Test("bootstrapDynamicEnv exposes the labeled host path")
    func bootstrapDynamicEnvFromLabel() {
        #expect(SSHAgentForwarding.bootstrapDynamicEnv(labels: [:]).isEmpty)
        #expect(
            SSHAgentForwarding.bootstrapDynamicEnv(labels: [SSHAgentForwarding.hostPathLabel: "/tmp/agent.sock"])
                == ["SSH_AUTH_SOCK": "/tmp/agent.sock"])
    }
}

// MARK: - Helpers

private func withCreateRouteApp(
    maxBodySize: ByteCount,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { app in
        // Map a thrown Abort (404 / 413) to its HTTP status so the tests can
        // observe it; without it an uncaught error has no defined HTTP mapping.
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
        // The body-size policy knob the hand-collected route now honors.
        app.routes.defaultMaxBodySize = maxBodySize
    }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.register(collection: ContainerCreateRoute(client: NoopContainerClient(), systemConfig: ContainerSystemConfig()))
        try await test(app)
    }
}

/// Minimal client — the create route returns 404 at the image-existence check
/// before it ever reaches the container backend, so every method is a no-op stub.
private struct NoopContainerClient: ClientContainerProtocol {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
