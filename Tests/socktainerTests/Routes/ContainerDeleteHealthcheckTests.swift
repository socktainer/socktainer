import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression tests for ContainerDeleteRoute healthcheck stop keying.
///
/// When getContainer returns nil (container already gone or hex ID unresolvable),
/// the route falls back to the request-provided id for healthManager.stop. This
/// means a loop keyed by the native name is not stopped — the test documents and
/// guards that behaviour so the warning log path is exercised.
@Suite("ContainerDeleteRoute — healthcheck stop keying")
struct ContainerDeleteHealthcheckTests {

    @Test("Delete with unresolvable id falls back to request id — native-keyed loop survives")
    func deleteWithNilContainerFallsBackToRequestId() async throws {
        let nativeId = "native-delete-ctr"
        let hexId = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3"

        let mgr = HealthCheckManager(
            probe: { _, _, _ in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000
        )

        // Seed a running loop keyed by the native ID, as ContainerStartRoute would have done.
        let config = HealthcheckConfig(
            Test: ["CMD", "true"],
            Interval: 1_000_000_000,
            Timeout: 1_000_000_000,
            Retries: 3,
            StartPeriod: nil
        )
        await mgr.start(containerId: nativeId, config: config)
        #expect(await mgr.currentHealth(for: nativeId) != nil)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[HealthCheckManagerKey.self] = mgr
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerDeleteRoute(client: NilLookupDeleteMock()))

            // DELETE with a hex id that resolves to nil — fallback path exercises the warning log
            try await app.testing().test(.DELETE, "/v1.51/containers/\(hexId)") { res async in
                #expect(res.status == .ok)
            }
        }

        // The fallback used hexId as the stop key, so the loop keyed by nativeId is orphaned.
        #expect(await mgr.currentHealth(for: nativeId) != nil, "Loop keyed by native id was not stopped")
        #expect(await mgr.currentHealth(for: hexId) == nil, "No loop was ever keyed by hex id")

        await mgr.stop(containerId: nativeId)
    }

    @Test("Delete with known native id stops the healthcheck loop")
    func deleteWithKnownNativeIdStopsLoop() async throws {
        let nativeId = "native-known-ctr"
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
        let containerConfig = ContainerConfiguration(id: nativeId, image: img, process: proc)
        let snapshot = ContainerSnapshot(configuration: containerConfig, status: .stopped, networks: [])

        let mgr = HealthCheckManager(
            probe: { _, _, _ in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000
        )
        let config = HealthcheckConfig(
            Test: ["CMD", "true"],
            Interval: 1_000_000_000,
            Timeout: 1_000_000_000,
            Retries: 3,
            StartPeriod: nil
        )
        await mgr.start(containerId: nativeId, config: config)
        #expect(await mgr.currentHealth(for: nativeId) != nil)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[HealthCheckManagerKey.self] = mgr
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerDeleteRoute(client: KnownContainerDeleteMock(snapshot: snapshot)))

            try await app.testing().test(.DELETE, "/v1.51/containers/\(nativeId)") { res async in
                #expect(res.status == .ok)
            }
        }

        #expect(await mgr.currentHealth(for: nativeId) == nil, "Loop must be stopped on delete")
    }
}

// MARK: - Mocks

/// Mock whose getContainer always returns nil — simulates an already-gone or unresolvable container.
private struct NilLookupDeleteMock: ClientContainerProtocol {
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

/// Mock whose getContainer returns a known snapshot, enabling the normal stop path.
private struct KnownContainerDeleteMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot
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
