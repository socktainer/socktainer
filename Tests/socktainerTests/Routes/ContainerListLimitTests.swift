import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// GET /containers/json must honor the `limit` query parameter: return the N
/// most recently created containers, newest first, including non-running ones
/// (a positive limit implies `all`), per the Docker Engine API.
@Suite("ContainerListRoute — limit query parameter")
struct ContainerListLimitTests {

    @Test("limit=1 returns only the most recently created container")
    func limitOneReturnsNewest() async throws {
        let newest = Self.snapshot(id: "newest", createdAt: 300)
        let mock = ListMock(containers: [
            Self.snapshot(id: "oldest", createdAt: 100),
            newest,
            Self.snapshot(id: "middle", createdAt: 200),
        ])

        let summaries = try await Self.list(mock: mock, path: "/v1.51/containers/json?limit=1")
        #expect(summaries.map(\.Id) == [DockerContainerID.hexId(for: newest)])
    }

    @Test("limit=2 returns the two newest containers, newest first")
    func limitTwoReturnsNewestPairOrdered() async throws {
        let newest = Self.snapshot(id: "newest", createdAt: 300)
        let middle = Self.snapshot(id: "middle", createdAt: 200)
        let mock = ListMock(containers: [
            Self.snapshot(id: "oldest", createdAt: 100),
            newest,
            middle,
        ])

        let summaries = try await Self.list(mock: mock, path: "/v1.51/containers/json?limit=2")
        #expect(summaries.map(\.Id) == [DockerContainerID.hexId(for: newest), DockerContainerID.hexId(for: middle)])
    }

    @Test("A positive limit implies all=true so stopped containers are included")
    func limitImpliesAll() async throws {
        let stoppedNew = Self.snapshot(id: "stopped-new", createdAt: 300, status: .stopped)
        let mock = ListMock(containers: [
            stoppedNew,
            Self.snapshot(id: "running-old", createdAt: 100),
        ])

        let summaries = try await Self.list(mock: mock, path: "/v1.51/containers/json?limit=1")
        #expect(summaries.map(\.Id) == [DockerContainerID.hexId(for: stoppedNew)])
        #expect(await mock.log.showAllValues == [true], "limit must request non-running containers from the client")
    }

    @Test("Without limit the full list is returned, newest first")
    func noLimitReturnsAllNewestFirst() async throws {
        let older = Self.snapshot(id: "older", createdAt: 100)
        let newer = Self.snapshot(id: "newer", createdAt: 200)
        let mock = ListMock(containers: [older, newer])

        let summaries = try await Self.list(mock: mock, path: "/v1.51/containers/json?all=1")
        #expect(summaries.map(\.Id) == [DockerContainerID.hexId(for: newer), DockerContainerID.hexId(for: older)])
    }

    @Test("limit=0 and negative limit neither truncate nor imply all", arguments: ["limit=0", "limit=-1"])
    func nonPositiveLimitIsIgnored(limitParam: String) async throws {
        let mock = ListMock(containers: [
            Self.snapshot(id: "a", createdAt: 100),
            Self.snapshot(id: "b", createdAt: 200),
        ])

        let summaries = try await Self.list(mock: mock, path: "/v1.51/containers/json?\(limitParam)")
        #expect(summaries.count == 2)
        #expect(await mock.log.showAllValues == [false], "A non-positive limit must not imply all")
    }

    // MARK: - Helpers

    private static func list(mock: ListMock, path: String) async throws -> [RESTContainerSummary] {
        var result: [RESTContainerSummary] = []
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: ContainerListRoute(client: mock))

            try await app.testing().test(.GET, path) { res async throws in
                #expect(res.status == .ok)
                result = try JSONDecoder().decode([RESTContainerSummary].self, from: Data(buffer: res.body))
            }
        }
        return result
    }

    /// Creation dates are injected via the legacy creation-timestamp label,
    /// which AppleContainerTimestampResolver falls back to when no container
    /// bundle exists on disk (as is the case for these synthetic ids).
    private static func snapshot(id shortId: String, createdAt: TimeInterval, status: RuntimeStatus = .running) -> ContainerSnapshot {
        // Prefix the id so no real container bundle can exist on the test
        // machine — the resolver would prefer the bundle's filesystem date
        // over the injected label.
        let id = "socktainer-test-limit-\(shortId)"
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
        var config = ContainerConfiguration(id: id, image: img, process: proc)
        config.labels = [AppleContainerTimestampResolver.legacyCreationTimestampLabel: String(createdAt)]
        return ContainerSnapshot(configuration: config, status: status, networks: [])
    }
}

// MARK: - Mocks

private actor ShowAllLog {
    var showAllValues: [Bool] = []
    func record(_ value: Bool) { showAllValues.append(value) }
}

/// Mock that returns a fixed container list and records the showAll argument.
private struct ListMock: ClientContainerProtocol {
    let containers: [ContainerSnapshot]
    let log = ShowAllLog()

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        await log.record(showAll)
        return containers
    }
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
