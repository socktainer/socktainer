import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// POST /containers/{id}/exec must reject an empty Cmd at create time, as
/// Docker does. Without the guard the empty command is stored and the later
/// exec start force-unwraps `cmd.first!`, crashing the whole daemon.
@Suite("ExecRoute — create Cmd validation")
struct ExecCreateRouteTests {

    @Test(
        "Empty or missing Cmd returns 400 with Docker's message",
        arguments: [#"{"Cmd":[]}"#, "{}"])
    func emptyCmdReturns400(payload: String) async throws {
        try await withRunningContainerApp { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/running-ctr/exec",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: payload)
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("No exec command specified"))
            }
        }
    }

    @Test("Non-empty Cmd still creates the exec instance")
    func nonEmptyCmdCreates() async throws {
        try await withRunningContainerApp { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/running-ctr/exec",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Cmd":["echo","hi"]}"#)
            ) { res async throws in
                #expect(res.status == .created)
                let created = try JSONDecoder().decode(CreateExecResponse.self, from: Data(buffer: res.body))
                #expect(!created.Id.isEmpty)
                // The stored config carries the command through to exec start.
                let stored = await ExecManager.shared.get(id: created.Id)
                #expect(stored?.cmd == ["echo", "hi"])
                await ExecManager.shared.remove(id: created.Id)
            }
        }
    }
}

/// Regression tests for the >16 KB request-body fix on `POST /containers/{id}/exec`,
/// mirroring `ContainerCreateRouteTests`' — see that file for the full explanation of
/// why `Request.body.collect()` silently caps at 16 KB under socktainer's `RegexRouter`.
/// An exec-create payload carries the caller's full environment (`Env`), which routinely
/// exceeds 16 KB for real dev tooling — VS Code Dev Containers' bundled Docker client
/// hits this on a fraction of the exec calls it makes during startup (issue #192),
/// surfacing as `422 Unprocessable Entity` from the truncated/malformed JSON.
///
/// As with `ContainerCreateRouteTests`, these run against a LIVE server (`.running`) on
/// an ephemeral port — the in-memory tester delivers an already-collected body, for which
/// `collect(max:)` ignores the limit, so only a real streamed body exercises the cap.
@Suite("ExecRoute — request body size")
struct ExecCreateRouteBodySizeTests {

    @Test("a >16 KB exec-create body (large Env) is collected, not rejected with 422/413")
    func largeBodyIsAccepted() async throws {
        let env = (0..<300).map { #""SOME_LONG_ENV_VAR_NAME_\#($0)=some_reasonably_long_value_\#($0)""# }
        let payload = #"{"Cmd":["echo","hi"],"Env":[\#(env.joined(separator: ","))]}"#
        #expect(payload.utf8.count > 16_384)

        try await withRunningContainerApp(maxBodySize: "64mb") { app in
            try await app.testing(method: .running(hostname: "127.0.0.1", port: 0)).test(
                .POST, "/v1.51/containers/running-ctr/exec",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: payload)
            ) { res async throws in
                #expect(res.status == .created, "large body must be collected and decoded, not 422/413")
                let created = try JSONDecoder().decode(CreateExecResponse.self, from: Data(buffer: res.body))
                await ExecManager.shared.remove(id: created.Id)
            }
        }
    }

    @Test("the configured body cap is still enforced (a body over the limit is 413)")
    func bodyOverCapIsRejected() async throws {
        let payload = #"{"Cmd":["echo","\#(String(repeating: "A", count: 4_096))"]}"#
        try await withRunningContainerApp(maxBodySize: "1kb") { app in
            try await app.testing(method: .running(hostname: "127.0.0.1", port: 0)).test(
                .POST, "/v1.51/containers/running-ctr/exec",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: payload)
            ) { res async in
                #expect(res.status == .payloadTooLarge)
            }
        }
    }

    @Test("an empty POST body returns 400, not a crash")
    func emptyBodyIsBadRequest() async throws {
        try await withRunningContainerApp(maxBodySize: "64mb") { app in
            try await app.testing().test(.POST, "/v1.51/containers/running-ctr/exec") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("a malformed JSON body returns 400, not 500")
    func malformedBodyIsBadRequest() async throws {
        try await withRunningContainerApp(maxBodySize: "64mb") { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/running-ctr/exec",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: "{ this is not valid json")
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }
}

// MARK: - Helpers

private func withRunningContainerApp(
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = EventBroadcaster()
        try app.register(collection: ExecRoute(client: RunningContainerMock()))
        try await test(app)
    }
}

private func withRunningContainerApp(
    maxBodySize: ByteCount,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { app in
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
        app.routes.defaultMaxBodySize = maxBodySize
    }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = EventBroadcaster()
        try app.register(collection: ExecRoute(client: RunningContainerMock()))
        try await test(app)
    }
}

/// Mock whose getContainer always returns a running snapshot, so createExec
/// reaches the request-body validation.
private struct RunningContainerMock: ClientContainerProtocol {
    private var snapshot: ContainerSnapshot {
        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
        )
        let img = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: "sha256:abc", size: 0
            )
        )
        let config = ContainerConfiguration(id: "running-ctr", image: img, process: proc)
        return ContainerSnapshot(configuration: config, status: .running, networks: [])
    }
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
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
