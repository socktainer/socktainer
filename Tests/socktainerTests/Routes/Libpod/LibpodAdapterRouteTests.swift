import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Podman sends the grace period of `stop`/`restart` as `timeout` (Docker-compat reads `t`) and
/// expects `containers.Remove` to answer a `[]RmReport`, even though Docker answers 204.
@Suite("Libpod routes — request/response adaptation")
struct LibpodAdapterRouteTests {
    @Test("stop honors podman's `timeout` query parameter")
    func stopTimeout() async throws {
        let client = RecordingClient()
        try await withApp(configure: { app in app.storage[EventBroadcasterKey.self] = EventBroadcaster() }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodContainerStopRoute(client: client))

            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/stop?timeout=7") { res async throws in
                #expect(res.status == .noContent)
            }
        }
        #expect(await client.stopTimeout == 7)
    }

    @Test("an explicit Docker `t` is not overridden by `timeout`")
    func dockerTimeoutWins() async throws {
        let client = RecordingClient()
        try await withApp(configure: { app in app.storage[EventBroadcasterKey.self] = EventBroadcaster() }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodContainerStopRoute(client: client))

            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/stop?t=3&timeout=7") { res async throws in
                #expect(res.status == .noContent)
            }
        }
        #expect(await client.stopTimeout == 3)
    }

    @Test("restart honors podman's `timeout` query parameter")
    func restartTimeout() async throws {
        let client = RecordingClient()
        try await withApp(configure: { app in app.storage[EventBroadcasterKey.self] = EventBroadcaster() }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodContainerRestartRoute(client: client))

            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/restart?timeout=4") { res async throws in
                #expect(res.status == .noContent)
            }
        }
        #expect(await client.restartTimeout == 4)
    }

    @Test("container delete answers 200 with a removal report")
    func deleteReport() async throws {
        let client = RecordingClient(status: .stopped)
        try await withApp(configure: { app in app.storage[EventBroadcasterKey.self] = EventBroadcaster() }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodContainerDeleteRoute(client: client))

            try await app.testing().test(.DELETE, "/v1.51/libpod/containers/ctr") { res async throws in
                #expect(res.status == .ok)
                let reports = try #require(try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [[String: Any]])
                #expect(reports.first?["Id"] as? String == "ctr")
            }
        }
        #expect(await client.deleted == "ctr")
    }

    @Test("a body-less libpod request is decoded as JSON once defaulted")
    func defaultsContentType() async throws {
        try await withApp(configure: { app in app.storage[EventBroadcasterKey.self] = EventBroadcaster() }) { app in
            app.post("probe") { req async throws -> String in
                LibpodAdapter.defaultToJSON(req)
                return try req.content.decode(ProbeBody.self).Detach ? "detached" : "attached"
            }
            try await app.testing().test(
                .POST, "probe", beforeRequest: { req in req.body = ByteBuffer(string: #"{"Detach":true}"#) }
            ) { res async throws in
                #expect(String(buffer: res.body) == "detached")
            }
        }
    }
}

private struct ProbeBody: Vapor.Content { let Detach: Bool }

private actor RecordingClient: ClientContainerProtocol {
    private let status: RuntimeStatus
    init(status: RuntimeStatus = .running) { self.status = status }
    private(set) var stopTimeout: Int?
    private(set) var restartTimeout: Int?
    private(set) var deleted: String?

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { makeSnapshot(status: status) }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws { stopTimeout = timeout }
    func restart(id: String, signal: String?, timeout: Int?) async throws { restartTimeout = timeout }
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws { deleted = id }
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait { RESTContainerWait(statusCode: 0) }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
}

private func makeSnapshot(status: RuntimeStatus) -> ContainerSnapshot {
    let process = ProcessConfiguration(
        executable: "/bin/sh", arguments: [], environment: [], workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
    let image = ImageDescription(
        reference: "alpine:latest",
        descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
    return ContainerSnapshot(configuration: ContainerConfiguration(id: "ctr", image: image, process: process), status: status, networks: [])
}
