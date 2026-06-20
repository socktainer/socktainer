import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Unit tests for ContainerAttachWSRoute parameter validation.
///
/// The core I/O paths (pipe bootstrap, WS↔pipe wiring, process lifecycle) require
/// live Apple Container infrastructure and are validated via real-world testing.
/// These tests cover the parameter validation paths that ARE unit-testable.
@Suite("ContainerAttachWSRoute — parameter validation")
struct ContainerAttachWSRouteTests {

    @Test("Unknown container returns 404")
    func unknownContainerReturns404() async throws {
        try await withWSRouteApp(client: NullContainerMock()) { app in
            try await app.testing().test(
                .GET,
                "/v1.51/containers/nonexistent/attach/ws?stream=1&stdout=1"
            ) { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    // Bootstrap failure and start failure paths call ContainerClient() directly
    // (not via the injected protocol) — live Apple Container infrastructure is
    // required to trigger them. The dual-ID exit-code pattern they use is
    // tested below via ContainerExitCodeStore directly.

    @Test("ExitCodeStore supports separate entries for container.id and hexId — prerequisite for dual-key recording")
    func exitCodeStoreDualKey() async {
        // Verifies that the store can hold independent entries for the same exit code
        // under two different keys (native container.id and raw request hexId).
        // The actual dual-recording call sites require live Apple Container infrastructure.
        let nativeId = "native-uuid-\(Int.random(in: 100000...999999))"
        let hexId = "hex-\(Int.random(in: 100000...999999))"

        await ContainerExitCodeStore.shared.set(id: nativeId, code: -1)
        await ContainerExitCodeStore.shared.set(id: hexId, code: -1)

        let nativeCode = await ContainerExitCodeStore.shared.get(id: nativeId)
        let hexCode = await ContainerExitCodeStore.shared.get(id: hexId)

        #expect(nativeCode == -1)
        #expect(hexCode == -1)

        // Cleanup so shared state doesn't bleed between tests.
        await ContainerExitCodeStore.shared.remove(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: hexId)
    }

    @Test("Found running container reaches webSocket upgrade (does not 404 or 400)")
    func foundRunningContainerPassesValidation() async throws {
        try await withWSRouteApp(client: FoundContainerMock(status: .running)) { app in
            try await app.testing().test(
                .GET,
                "/v1.51/containers/test-container/attach/ws?stream=1&stdout=1"
            ) { res async in
                // Validation passes — VaporTesting sends a plain GET (no WS upgrade headers)
                // so NIO refuses the upgrade and returns a non-404/non-400 response.
                #expect(res.status != .notFound)
                #expect(res.status != .badRequest)
            }
        }
    }

    @Test("Found stopped container reaches webSocket upgrade (does not 404 or 400)")
    func foundStoppedContainerPassesValidation() async throws {
        try await withWSRouteApp(client: FoundContainerMock(status: .stopped)) { app in
            try await app.testing().test(
                .GET,
                "/v1.51/containers/test-container/attach/ws?stream=1&stdout=1"
            ) { res async in
                #expect(res.status != .notFound)
                #expect(res.status != .badRequest)
            }
        }
    }

    @Test("Missing container ID returns 400")
    func missingContainerIdReturns400() async throws {
        // The regex route requires a non-empty {id} capture — an empty segment
        // should not match at all or return 400.
        try await withWSRouteApp(client: NullContainerMock()) { app in
            try await app.testing().test(
                .GET,
                "/v1.51/containers//attach/ws?stream=1&stdout=1"
            ) { res async in
                // Either not found (no route match) or bad request.
                #expect(res.status == .notFound || res.status == .badRequest)
            }
        }
    }
}

// MARK: - Helpers

private func withWSRouteApp(
    client: some ClientContainerProtocol,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.register(collection: ContainerAttachWSRoute(client: client))
        try await test(app)
    }
}

private struct FoundContainerMock: ClientContainerProtocol {
    let status: RuntimeStatus
    func getContainer(id: String) async throws -> ContainerSnapshot? {
        let processConfig = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
        )
        let imageDesc = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: "sha256:abc", size: 0)
        )
        let config = ContainerConfiguration(id: id, image: imageDesc, process: processConfig)
        return ContainerSnapshot(
            configuration: config, status: status, networks: [],
            startedDate: Date(timeIntervalSinceNow: -10))
    }
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
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
