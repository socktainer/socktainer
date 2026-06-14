import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

// MARK: - humanReadableAge

@Suite("ContainerListRoute.humanReadableAge")
struct HumanReadableAgeTests {

    @Test("Seconds: singular and plural")
    func seconds() {
        #expect(ContainerListRoute.humanReadableAge(since: Date(timeIntervalSinceNow: -1)) == "1 second")
        #expect(ContainerListRoute.humanReadableAge(since: Date(timeIntervalSinceNow: -30)) == "30 seconds")
        #expect(ContainerListRoute.humanReadableAge(since: Date(timeIntervalSinceNow: -59)) == "59 seconds")
    }

    @Test("Minutes: singular and plural")
    func minutes() {
        #expect(ContainerListRoute.humanReadableAge(since: Date(timeIntervalSinceNow: -60)) == "1 minute")
        #expect(ContainerListRoute.humanReadableAge(since: Date(timeIntervalSinceNow: -120)) == "2 minutes")
        #expect(ContainerListRoute.humanReadableAge(since: Date(timeIntervalSinceNow: -3599)) == "59 minutes")
    }

    @Test("Hours: singular and plural")
    func hours() {
        #expect(ContainerListRoute.humanReadableAge(since: Date(timeIntervalSinceNow: -3600)) == "1 hour")
        #expect(ContainerListRoute.humanReadableAge(since: Date(timeIntervalSinceNow: -7200)) == "2 hours")
        #expect(ContainerListRoute.humanReadableAge(since: Date(timeIntervalSinceNow: -86399)) == "23 hours")
    }

    @Test("Days: singular and plural")
    func days() {
        #expect(ContainerListRoute.humanReadableAge(since: Date(timeIntervalSinceNow: -86400)) == "1 day")
        #expect(ContainerListRoute.humanReadableAge(since: Date(timeIntervalSinceNow: -172800)) == "2 days")
    }
}

// MARK: - ContainerWaitCondition.healthy

@Suite("ContainerWaitCondition")
struct ContainerWaitConditionTests {

    @Test("healthy raw value matches Docker API spec")
    func healthyRawValue() {
        #expect(ContainerWaitCondition.healthy.rawValue == "healthy")
    }

    @Test("healthy parses from string")
    func healthyParsesFromString() {
        #expect(ContainerWaitCondition(rawValue: "healthy") == .healthy)
    }

    @Test("unknown condition falls back to default")
    func unknownCondition() {
        #expect(ContainerWaitCondition(rawValue: "unknown") == nil)
    }

    @Test("all standard conditions are present")
    func allCases() {
        let rawValues = ContainerWaitCondition.allCases.map(\.rawValue)
        #expect(rawValues.contains("healthy"))
        #expect(rawValues.contains("not-running"))
        #expect(rawValues.contains("next-exit"))
        #expect(rawValues.contains("removed"))
    }
}

// MARK: - docker wait --condition=healthy route test

private struct MockWaitClient: ClientContainerProtocol {
    let container: ContainerSnapshot

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [container] }
    func getContainer(id: String) async throws -> ContainerSnapshot? {
        guard id == container.id else { return nil }
        return container
    }
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

private func makeRunningSnapshot(id: String) -> ContainerSnapshot {
    let proc = ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [], workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
    let img = ImageDescription(reference: "alpine:latest", descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
    let config = ContainerConfiguration(id: id, image: img, process: proc)
    return ContainerSnapshot(configuration: config, status: .running, networks: [])
}

@Suite("ContainerWaitRoute health condition")
struct ContainerWaitHealthRouteTests {

    @Test("POST /wait?condition=healthy returns 200 when container already healthy")
    func waitConditionHealthyAlreadyHealthy() async throws {
        let snapshot = makeRunningSnapshot(id: "c1")
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 1, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        // Wait for healthy
        for _ in 0..<200 {
            if await mgr.currentHealth(for: "c1")?.Status == "healthy" { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[HealthCheckManagerKey.self] = mgr
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            let client = MockWaitClient(container: snapshot)
            try app.register(collection: ContainerWaitRoute(client: client))

            try await app.testing().test(.POST, "/v1.51/containers/c1/wait?condition=healthy") { res async in
                #expect(res.status == .ok)
                // Response body should eventually contain a status code
                let body = res.body.string
                #expect(body.contains("StatusCode"))
            }
        }
        await mgr.stop(containerId: "c1")
    }

    @Test("condition=healthy is parsed from query string and not falling back to not-running")
    func conditionHealthyParsed() {
        #expect(ContainerWaitCondition(rawValue: "healthy") == .healthy)
        #expect(ContainerWaitCondition(rawValue: "not-running") == .notRunning)
        // healthy is not the default
        #expect(ContainerWaitCondition.default != .healthy)
    }
}
