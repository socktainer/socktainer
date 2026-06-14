import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression tests for the hex-ID / healthcheck key mismatch (issue introduced by #213).
///
/// Before the fix, ContainerStartRoute called ContainerClient().get(id: hexId) directly —
/// which fails for hex digests — so the healthcheck loop was never started. Even if it had
/// started, it used the hex ID as the HealthCheckManager key while ContainerInspectRoute
/// and ContainerListRoute looked up by container.id (the native Apple Container name),
/// causing State.Health.Status to always return empty.
///
/// The fix: reuse startedSnapshot.id (native name) as the key.
@Suite("ContainerStartRoute — healthcheck native-ID keying")
struct ContainerStartHealthcheckTests {

    // MARK: - Helpers

    /// Returns a snapshot whose labels include a valid healthcheck config, simulating
    /// a container created with `--health-cmd true`.
    private func makeSnapshotWithHealthcheck(nativeId: String) throws -> ContainerSnapshot {
        let proc = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
        let img = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: "sha256:abc",
                size: 0
            )
        )
        let config = HealthcheckConfig(
            Test: ["CMD", "true"],
            Interval: 1_000_000_000,
            Timeout: 1_000_000_000,
            Retries: 3,
            StartPeriod: nil
        )
        let json = try JSONEncoder().encode(config)
        let jsonString = String(data: json, encoding: .utf8)!
        var containerConfig = ContainerConfiguration(id: nativeId, image: img, process: proc)
        containerConfig.labels = [HealthCheckManager.healthcheckLabel: jsonString]
        return ContainerSnapshot(configuration: containerConfig, status: .stopped, networks: [])
    }

    // MARK: - Tests

    @Test("Start route keys HealthCheckManager by native container ID (snapshot.id)")
    func healthcheckKeyedByNativeId() async throws {
        let nativeId = "my-native-container"
        let hexId = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
        let snapshot = try makeSnapshotWithHealthcheck(nativeId: nativeId)

        // Mock: getContainer(id: hexId) returns snapshot with native ID
        let mock = HealthcheckStartMock(snapshot: snapshot, nativeId: nativeId)
        let mgr = HealthCheckManager(
            probe: { _, _, _ in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000
        )

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[HealthCheckManagerKey.self] = mgr
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStartRoute(client: mock))

            // Simulate docker start with hex ID in the URL
            try await app.testing().test(.POST, "/v1.51/containers/\(hexId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        // HealthCheckManager must be keyed by the native ID, not the hex ID
        let byNative = await mgr.currentHealth(for: nativeId)
        let byHex = await mgr.currentHealth(for: hexId)
        #expect(byNative != nil, "Loop should be keyed by native container ID")
        #expect(byHex == nil, "Loop must NOT be keyed by hex digest")

        await mgr.stop(containerId: nativeId)
    }

    @Test("Start route does not start healthcheck when label is missing")
    func noHealthcheckWithoutLabel() async throws {
        let nativeId = "no-healthcheck-ctr"
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
        let config = ContainerConfiguration(id: nativeId, image: img, process: proc)
        let snapshot = ContainerSnapshot(configuration: config, status: .stopped, networks: [])
        let mock = HealthcheckStartMock(snapshot: snapshot, nativeId: nativeId)
        let mgr = HealthCheckManager(probe: { _, _, _ in 0 }, intervalFloorNs: 1_000_000)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[HealthCheckManagerKey.self] = mgr
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStartRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        #expect(await mgr.currentHealth(for: nativeId) == nil)
    }
}

// MARK: - Mock

/// Mock that returns `snapshot` for any `getContainer` call and no-ops for `start`.
private struct HealthcheckStartMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot
    let nativeId: String

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
