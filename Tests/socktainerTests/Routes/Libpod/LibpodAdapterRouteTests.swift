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

    @Test("delete of a missing container is 404, but an empty success with ignore=true")
    func deleteIgnoresMissing() async throws {
        let client = RecordingClient(status: .stopped, missing: true)
        try await withApp(configure: { app in app.storage[EventBroadcasterKey.self] = EventBroadcaster() }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodContainerDeleteRoute(client: client))

            try await app.testing().test(.DELETE, "/v1.51/libpod/containers/gone") { res async throws in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.DELETE, "/v1.51/libpod/containers/gone?ignore=true") { res async throws in
                #expect(res.status == .ok)
                let reports = try #require(try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [Any])
                #expect(reports.isEmpty)
            }
        }
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

/// Requests podman's client sends that the Docker-compat handlers read differently.
@Suite("Libpod routes — podman request translation")
struct LibpodRequestTranslationTests {
    private func withLibpodApp(_ body: (Application) async throws -> Void) async throws {
        try await withApp(configure: { app in app.storage[EventBroadcasterKey.self] = EventBroadcaster() }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try await body(app)
        }
    }

    @Test("a malformed JSON body is a 400, not a 500")
    func malformedJSONIsBadRequest() async throws {
        try await withApp(configure: { app in app.middleware.use(DockerErrorMiddleware()) }) { app in
            app.post("probe") { req async throws -> String in
                _ = try await LibpodAdapter.jsonObjectBody(of: req)
                return "ok"
            }
            try await app.testing().test(.POST, "probe", beforeRequest: { req in req.body = ByteBuffer(string: "{not json") }) { res async in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.POST, "probe", beforeRequest: { req in req.body = ByteBuffer(string: "[1]") }) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("`podman rm -v` (volumes=true) reaches Docker-compat as v=true")
    func deleteAliasesVolumes() async throws {
        try await withApp(configure: { _ in }) { app in
            app.delete("probe") { req async throws -> String in
                LibpodContainerDeleteRoute.prepare(req).query[String.self, at: "v"] ?? "unset"
            }
            try await app.testing().test(.DELETE, "probe?volumes=true") { res async in
                #expect(String(buffer: res.body) == "true")
            }
        }
    }

    @Test("`podman ps --last` reaches Docker-compat as limit, overriding an explicit limit")
    func listAliasesLast() async throws {
        try await withApp(configure: { _ in }) { app in
            app.get("probe") { req async throws -> String in
                LibpodContainerListRoute.prepare(req).query[String.self, at: "limit"] ?? "unset"
            }
            try await app.testing().test(.GET, "probe?last=1") { res async in
                #expect(String(buffer: res.body) == "1")
            }
            try await app.testing().test(.GET, "probe?limit=5&last=2") { res async in
                #expect(String(buffer: res.body) == "2")
            }
            try await app.testing().test(.GET, "probe?limit=5") { res async in
                #expect(String(buffer: res.body) == "5")
            }
        }
    }

    @Test("the libpod path-stat header uses the URL-safe base64 alphabet podman decodes with")
    func statHeaderIsURLSafe() {
        #expect(Data([0xfb, 0xff]).base64EncodedString() == "+/8=")
        #expect(LibpodContainerArchiveRoute.urlSafeBase64(Data([0xfb, 0xff])) == "-_8=")
    }

    @Test("podman's infinite stop timeout (4294967295) is clamped instead of trapping")
    func infiniteStopTimeoutIsClamped() {
        #expect(ClientContainerService.stopTimeoutSeconds(4_294_967_295) == Int32.max)
        #expect(ClientContainerService.stopTimeoutSeconds(nil) == 5)
        #expect(ClientContainerService.stopTimeoutSeconds(-1) == -1)
    }

    @Test("a bare `podman stats` (no containers, all=false) reports running containers instead of a 400")
    func statsWithoutNamesListsRunning() async throws {
        let client = RecordingClient()
        try await withLibpodApp { app in
            try app.register(collection: LibpodContainersStatsRoute(client: client))
            try await app.testing().test(.GET, "/v1.51/libpod/containers/stats?stream=false") { res async throws in
                #expect(res.status == .ok)
                let report = try #require(try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])
                #expect((report["Stats"] as? [Any])?.isEmpty == true)
            }
        }
    }

    @Test("update refuses an environment change instead of dropping it")
    func updateRejectsEnv() async throws {
        let client = RecordingClient()
        try await withLibpodApp { app in
            try app.register(collection: LibpodContainerUpdateRoute(client: client))
            try await app.testing().test(
                .POST, "/v1.51/libpod/containers/ctr/update?restartPolicy=no",
                beforeRequest: { req in req.body = ByteBuffer(string: #"{"Env":["A=1"]}"#) }
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("update answers the container's full ID as a bare JSON string")
    func updateAnswersFullID() async throws {
        let client = RecordingClient()
        let fullID = DockerContainerID.hexId(for: makeSnapshot(status: .running))
        try await withLibpodApp { app in
            try app.register(collection: LibpodContainerUpdateRoute(client: client))
            try await app.testing().test(
                .POST, "/v1.51/libpod/containers/ctr/update?restartPolicy=no",
                beforeRequest: { req in req.body = ByteBuffer(string: #"{"Env":[],"UnsetEnv":null}"#) }
            ) { res async throws in
                #expect(res.status == .created)
                let id = try JSONSerialization.jsonObject(with: Data(buffer: res.body), options: [.fragmentsAllowed]) as? String
                #expect(id == fullID)
            }
        }
    }
}

private struct ProbeBody: Vapor.Content { let Detach: Bool }

private actor RecordingClient: ClientContainerProtocol {
    private let status: RuntimeStatus
    private let missing: Bool
    init(status: RuntimeStatus = .running, missing: Bool = false) {
        self.status = status
        self.missing = missing
    }
    private(set) var stopTimeout: Int?
    private(set) var restartTimeout: Int?
    private(set) var deleted: String?

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { missing ? nil : makeSnapshot(status: status) }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws { stopTimeout = timeout }
    func restart(id: String, signal: String?, timeout: Int?) async throws { restartTimeout = timeout }
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {
        if missing { throw ClientContainerError.notFound(id: id) }
        deleted = id
    }
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
