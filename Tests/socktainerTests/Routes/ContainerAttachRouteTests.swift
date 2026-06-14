import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Unit tests for ContainerAttachRoute parameter validation (issue #220).
///
/// The core fix (pipe-based output delivery for non-interactive docker run) requires
/// live Apple Container infrastructure and is validated via real-world testing:
///   docker run --rm alpine echo hi                          → hi
///   docker run -a STDOUT -a STDERR --rm alpine sh -c '...' → Container started
///   docker run --rm alpine sh -c 'echo l1; echo l2'        → l1 / l2
/// These tests cover the parameter validation paths that ARE unit-testable.
@Suite("ContainerAttachRoute — parameter validation")
struct ContainerAttachRouteTests {

    @Test("Container not found returns 404")
    func unknownContainerReturns404() async throws {
        let client = NullContainerMock()
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerAttachRoute(client: client))

            try await app.testing().test(
                .POST,
                "/v1.51/containers/nonexistent/attach?stream=1&stdout=1"
            ) { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("Attach without stream=1 or logs=1 returns 400")
    func noStreamOrLogsReturns400() async throws {
        let client = NullContainerMock()
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerAttachRoute(client: client))

            // No stream or logs param → should be rejected before even looking up container
            try await app.testing().test(
                .POST,
                "/v1.51/containers/test-ctr/attach"
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }
}

// MARK: - Helpers

/// Mock that returns nil for all container lookups (simulates "not found").
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
