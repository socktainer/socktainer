import ContainerAPIClient
import ContainerResource
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Unit tests for POST /exec/{id}/resize.
///
/// The process.resize() call requires a live Apple Container process and is
/// validated via integration testing (POST .../resize?h=50&w=120 → 200 against
/// a running container). These tests cover the parameter validation and exec-ID
/// lookup that are unit-testable without infrastructure.
@Suite("ExecResizeRoute")
struct ExecResizeRouteTests {

    @Test("unknown exec ID returns 404")
    func unknownExecIdReturns404() async throws {
        try await withExecRouteApp { app in
            try await app.testing().test(
                .POST,
                "/v1.51/exec/nonexistent-id/resize?h=40&w=120"
            ) { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("missing height parameter returns 400")
    func missingHeightReturns400() async throws {
        try await withExecRouteApp { app in
            try await app.testing().test(
                .POST,
                "/v1.51/exec/any-id/resize?w=120"
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("missing width parameter returns 400")
    func missingWidthReturns400() async throws {
        try await withExecRouteApp { app in
            try await app.testing().test(
                .POST,
                "/v1.51/exec/any-id/resize?h=40"
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("known exec ID with no running process returns 200")
    func knownExecIdNoProcessReturns200() async throws {
        // Register an exec so ExecManager.shared.get() returns non-nil,
        // but leave ProcessRegistry empty (simulates: exec ran and exited).
        let config = ExecManager.ExecConfig(
            containerId: "test-ctr",
            cmd: ["sh"],
            attachStdin: false,
            attachStdout: true,
            attachStderr: true,
            tty: true,
            detach: false,
            env: [],
            user: nil,
            workingDir: nil
        )
        let execId = await ExecManager.shared.create(config: config)
        defer { Task { await ExecManager.shared.remove(id: execId) } }

        try await withExecRouteApp { app in
            try await app.testing().test(
                .POST,
                "/v1.51/exec/\(execId)/resize?h=40&w=120"
            ) { res async in
                #expect(res.status == .ok)
            }
        }
    }
}

// MARK: - Helpers

private func withExecRouteApp(
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.register(collection: ExecRoute(client: NullContainerMock()))
        try await test(app)
    }
}

private struct NullContainerMock: ClientContainerProtocol {
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
    func prune(filters: [String: [String]]) async throws -> (
        deletedContainers: [String], spaceReclaimed: Int64
    ) { ([], 0) }
}
