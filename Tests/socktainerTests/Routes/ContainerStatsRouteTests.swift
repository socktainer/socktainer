import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression tests for issue #463: `GET /containers/{id}/stats` only found a
/// container by its native name, and reported neither the container's name nor
/// its Docker ID. It has to resolve references the way the other container
/// routes do (`docker stats` with no arguments passes full hex IDs), sample by
/// the native ID, and report `id` and `name` as Docker does.
@Suite("ContainerStatsRoute")
struct ContainerStatsRouteTests {

    /// Resolves a reference like `ClientContainerService.getContainer`: the
    /// native ID first, then a full or prefix Docker ID, throwing when a
    /// prefix matches more than one container.
    private struct ResolvingClient: ClientContainerProtocol {
        let containers: [ContainerSnapshot]

        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { containers }
        func getContainer(id: String) async throws -> ContainerSnapshot? {
            if let container = containers.first(where: { $0.id == id }) { return container }
            let matches = containers.filter { DockerContainerID.hexId(for: $0).hasPrefix(id) }
            if matches.count > 1 {
                throw ClientContainerError.ambiguousId(reference: id, matches: matches.map(\.id))
            }
            return matches.first
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

    /// Records which native IDs were sampled.
    private actor SampledIDs {
        private(set) var ids: [String] = []
        func record(_ id: String) { ids.append(id) }
    }

    private static func makeSnapshot(id: String) -> ContainerSnapshot {
        let process = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [], workingDirectory: "/",
            terminal: false, user: .id(uid: 0, gid: 0))
        let image = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
        return ContainerSnapshot(
            configuration: ContainerConfiguration(id: id, image: image, process: process),
            status: .running,
            networks: [],
            startedDate: Date(timeIntervalSinceNow: -30))
    }

    private func withRoute(
        containers: [ContainerSnapshot],
        sampled: SampledIDs,
        test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            let route = ContainerStatsRoute(
                client: ResolvingClient(containers: containers),
                sample: { id in
                    await sampled.record(id)
                    return ContainerStats(
                        id: id, memoryUsageBytes: 1024, memoryLimitBytes: 4096, cpuUsageUsec: 10,
                        networkRxBytes: nil, networkTxBytes: nil, blockReadBytes: nil, blockWriteBytes: nil,
                        numProcesses: 1)
                },
                sampleInterval: .milliseconds(10))
            try app.register(collection: route)
            try await test(app)
        }
    }

    @Test(
        "Resolves a container by name, full Docker ID, or ID prefix, and reports its Docker ID and name",
        arguments: ["name", "full ID", "ID prefix"])
    func resolvesReferenceAndReportsIdentity(form: String) async throws {
        let container = Self.makeSnapshot(id: "web")
        let hexId = DockerContainerID.hexId(for: container)
        let reference =
            switch form {
            case "name": "web"
            case "full ID": hexId
            default: String(hexId.prefix(12))
            }
        let sampled = SampledIDs()

        try await withRoute(containers: [container], sampled: sampled) { app in
            try await app.testing().test(.GET, "/v1.51/containers/\(reference)/stats?stream=false") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any]
                #expect(json?["id"] as? String == hexId)
                #expect(json?["name"] as? String == "/web")
            }
        }
        // Samples are taken by native ID, whatever form the request used.
        #expect(await sampled.ids == ["web", "web"])
    }

    @Test("An ambiguous ID prefix returns 400 without sampling, as the other container routes do")
    func ambiguousPrefixIsBadRequest() async throws {
        // 17 containers over 16 hex digits: at least two share a first character.
        let containers = (0...16).map { Self.makeSnapshot(id: "c\($0)") }
        let firstChars = containers.map { DockerContainerID.hexId(for: $0).prefix(1) }
        let shared = try #require(firstChars.first { char in firstChars.filter { $0 == char }.count > 1 })
        let sampled = SampledIDs()

        try await withRoute(containers: containers, sampled: sampled) { app in
            try await app.testing().test(.GET, "/v1.51/containers/\(shared)/stats?stream=false") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("ambiguous container reference"))
            }
        }
        #expect(await sampled.ids.isEmpty)
    }

    @Test("Unknown container returns 404 without sampling")
    func unknownContainerIsNotFound() async throws {
        let sampled = SampledIDs()
        try await withRoute(containers: [Self.makeSnapshot(id: "web")], sampled: sampled) { app in
            try await app.testing().test(.GET, "/v1.51/containers/nope/stats?stream=false") { res async in
                #expect(res.status == .notFound)
            }
        }
        #expect(await sampled.ids.isEmpty)
    }
}
