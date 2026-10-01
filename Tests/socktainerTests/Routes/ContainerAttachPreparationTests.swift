import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("Attach pre-start preparation")
struct ContainerAttachPreparationTests {
    @Test("staged-file preparation runs before HTTP bootstrap", arguments: ["0", "1"])
    func httpPreparation(stdin: String) async throws {
        let client = PreparationClient(status: .stopped)
        try await withPreparationApp(client: client) { app in
            try await app.testing().test(
                .POST, "/containers/test/attach?stream=1&stdout=1&stdin=\(stdin)"
            ) { response async in
                #expect(response.status == .conflict)
                #expect(response.body.string.contains("staged-file preparation failed"))
            }
        }
        #expect(await client.preparedIDs == ["test"])
    }

    @Test("staged-file preparation runs before WebSocket upgrade")
    func websocketPreparation() async throws {
        let client = PreparationClient(status: .stopped)
        try await withPreparationApp(client: client) { app in
            try await app.testing().test(
                .GET, "/containers/test/attach/ws?stream=1&stdout=1"
            ) { response async in
                #expect(response.status == .conflict)
                #expect(response.body.string.contains("staged-file preparation failed"))
            }
        }
        #expect(await client.preparedIDs == ["test"])
    }

    @Test("attaching to a running container does not prepare or rebuild it")
    func runningWebsocket() async throws {
        let client = PreparationClient(status: .running)
        try await withPreparationApp(client: client) { app in
            try await app.testing().test(
                .GET, "/containers/test/attach/ws?stream=1&stdout=1"
            ) { response async in
                #expect(response.status != .conflict)
            }
        }
        #expect(await client.preparedIDs.isEmpty)
    }
}

private func withPreparationApp(
    client: PreparationClient,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let router = app.regexRouter(with: app.logger)
        app.setRegexRouter(router)
        router.installMiddleware(on: app)
        try app.register(collection: ContainerAttachRoute(client: client))
        try app.register(collection: ContainerAttachWSRoute(client: client))
        try await test(app)
    }
}

private actor PreparationClient: ClientContainerProtocol {
    let status: RuntimeStatus
    private(set) var preparedIDs: [String] = []

    init(status: RuntimeStatus) { self.status = status }

    func prepareForStart(container: ContainerSnapshot) async throws {
        preparedIDs.append(container.id)
        // Stop at the preparation boundary: a regression would instead try
        // to bootstrap a real VM (HTTP) or upgrade the connection (WebSocket).
        throw Abort(.conflict, reason: "staged-file preparation failed")
    }

    func getContainer(id: String) async throws -> ContainerSnapshot? {
        let process = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
        let image = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
        return ContainerSnapshot(
            configuration: ContainerConfiguration(id: id, image: image, process: process),
            status: status, networks: [])
    }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
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
