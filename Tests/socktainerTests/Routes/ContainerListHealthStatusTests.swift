import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

// MARK: - Minimal mock client

private struct MockContainerClient: ClientContainerProtocol {
    let containers: [ContainerSnapshot]

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { containers }
    func getContainer(id: String) async throws -> ContainerSnapshot? { containers.first { $0.id == id } }
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

// MARK: - Helpers

private func makeSnapshot(id: String) -> ContainerSnapshot {
    let processConfig = ProcessConfiguration(
        executable: "/bin/sh",
        arguments: [],
        environment: [],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0)
    )
    let imageDesc = ImageDescription(
        reference: "alpine:latest",
        descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
    )
    let config = ContainerConfiguration(id: id, image: imageDesc, process: processConfig)
    return ContainerSnapshot(
        configuration: config,
        status: .running,
        networks: [],
        startedDate: Date(timeIntervalSinceNow: -30)  // started 30 seconds ago
    )
}

// MARK: - Tests

@Suite("ContainerListRoute health status")
struct ContainerListHealthStatusTests {

    private func withRoute(
        containers: [ContainerSnapshot],
        healthManager: HealthCheckManager? = nil,
        test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)

            if let healthManager {
                app.storage[HealthCheckManagerKey.self] = healthManager
            }
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()

            let client = MockContainerClient(containers: containers)
            try app.register(collection: ContainerListRoute(client: client))
            try await test(app)
        }
    }

    @Test("Status is plain mobyState when no healthcheck configured")
    func statusWithoutHealthcheck() async throws {
        let snapshot = makeSnapshot(id: "c1")
        try await withRoute(containers: [snapshot]) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                #expect(summaries.first?.Status.hasPrefix("Up") == true)
                #expect(summaries.first?.Status.range(of: "\\((starting|healthy|unhealthy)\\)", options: .regularExpression) == nil)
            }
        }
    }

    @Test("Status includes (health: starting) immediately after healthcheck is registered")
    func statusWithHealthcheckStarting() async throws {
        let snapshot = makeSnapshot(id: "c2")
        let mgr = HealthCheckManager(
            probe: { _, _, _ in
                // Slow probe — stays in "starting"
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c2", config: cfg)
        defer { Task { await mgr.stop(containerId: "c2") } }

        try await withRoute(containers: [snapshot], healthManager: mgr) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                #expect(summaries.first?.Status.contains("(starting)") == true)
            }
        }
    }

    @Test("Status is plain mobyState (no health suffix) for running container without healthcheck — filter returns 'none'")
    func noHealthcheckFilterNone() async throws {
        let snapshot = makeSnapshot(id: "c-none")
        let mgr = HealthCheckManager(probe: { _, _, _ in 0 }, intervalFloorNs: 1_000_000)
        // mgr has no entry for "c-none" — no healthcheck started

        try await withRoute(containers: [snapshot], healthManager: mgr) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                // Status should be plain "running" (no health suffix)
                #expect(summaries.first?.Status.hasPrefix("Up") == true)
                #expect(summaries.first?.Status.range(of: "\\((starting|healthy|unhealthy)\\)", options: .regularExpression) == nil)
            }
            // Filter by health=none should return the container
            try await app.testing().test(.GET, "/v1.51/containers/json?filters=%7B%22health%22%3A%5B%22none%22%5D%7D") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                #expect(summaries.count == 1)
            }
            // Filter by health=healthy should NOT return the container
            try await app.testing().test(.GET, "/v1.51/containers/json?filters=%7B%22health%22%3A%5B%22healthy%22%5D%7D") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                #expect(summaries.count == 0)
            }
        }
    }

    @Test("Status includes (health: healthy) once probe passes")
    func statusWithHealthcheckHealthy() async throws {
        let snapshot = makeSnapshot(id: "c3")
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c3", config: cfg)
        // Wait until healthy
        for _ in 0..<200 {
            if await mgr.currentHealth(for: "c3")?.Status == "healthy" { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        defer { Task { await mgr.stop(containerId: "c3") } }

        try await withRoute(containers: [snapshot], healthManager: mgr) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                #expect(summaries.first?.Status.contains("(healthy)") == true)
            }
        }
    }
}
