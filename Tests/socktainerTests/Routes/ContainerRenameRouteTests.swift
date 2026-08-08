import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private struct RenameClient: ClientContainerProtocol {
    let snapshots: [ContainerSnapshot]
    let metadataStore: DockerContainerMetadataStore?

    init(
        snapshots: [ContainerSnapshot],
        metadataStore: DockerContainerMetadataStore? = nil
    ) {
        self.snapshots = snapshots
        self.metadataStore = metadataStore
    }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { snapshots }
    func getContainer(id: String) async throws -> ContainerSnapshot? {
        if let metadataStore {
            for snapshot in snapshots {
                if await metadataStore.name(nativeID: snapshot.id)
                    == DockerContainerMetadataStore.normalized(id)
                {
                    return snapshot
                }
            }
        } else if let native = snapshots.first(where: { $0.id == id }) {
            return native
        }
        return snapshots.first { DockerContainerID.hexId(for: $0).hasPrefix(id) }
    }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait { .init(statusCode: 0) }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
}

private func renameSnapshot(_ id: String) -> ContainerSnapshot {
    let process = ProcessConfiguration(
        executable: "/bin/true", arguments: [], environment: [], workingDirectory: "/",
        terminal: false, user: .id(uid: 0, gid: 0)
    )
    let image = ImageDescription(
        reference: "alpine:latest",
        descriptor: Descriptor(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:abc", size: 1)
    )
    return ContainerSnapshot(
        configuration: ContainerConfiguration(id: id, image: image, process: process),
        status: .stopped,
        networks: []
    )
}

@Suite("Container rename API", .serialized)
struct ContainerRenameRouteTests {
    @Test("rename is durable, preserves Docker identity, emits an event, and rejects conflicts")
    func renameAndConflict() async throws {
        let metadataStore = DockerContainerMetadataStore()

        let old = renameSnapshot("compose-replacement-123")
        let occupied = renameSnapshot("other-native")
        try await metadataStore.set(nativeID: old.id, name: "compose-replacement-123", publishedPorts: [])
        try await metadataStore.set(nativeID: occupied.id, name: "occupied", publishedPorts: [])
        let stableID = DockerContainerID.hexId(for: old)

        try await withApp(
            configure: { _ in },
            { app in
                let router = app.regexRouter(with: app.logger)
                app.setRegexRouter(router)
                router.installMiddleware(on: app)
                app.middleware.use(DockerErrorMiddleware())
                let broadcaster = EventBroadcaster()
                app.storage[EventBroadcasterKey.self] = broadcaster
                try app.register(
                    collection: ContainerRenameRoute(
                        client: RenameClient(
                            snapshots: [old, occupied],
                            metadataStore: metadataStore
                        ),
                        metadataStore: metadataStore
                    )
                )

                var iterator = await broadcaster.stream().makeAsyncIterator()
                try await app.testing().test(
                    .POST,
                    "/v1.51/containers/compose-replacement-123/rename?name=postgres"
                ) { response async throws in
                    #expect(response.status == .noContent)
                }
                #expect(await metadataStore.name(nativeID: old.id) == "postgres")
                #expect(DockerContainerID.hexId(for: old) == stableID)
                let event = await iterator.next()
                #expect(event?.Action == "rename")
                #expect(event?.Actor.ID == stableID)
                #expect(event?.Actor.Attributes["name"] == "postgres")
                #expect(event?.Actor.Attributes["oldName"] == "/compose-replacement-123")

                try await app.testing().test(
                    .POST,
                    "/v1.51/containers/\(stableID)/rename?name=occupied"
                ) { response async throws in
                    #expect(response.status == .conflict)
                }
                try await app.testing().test(
                    .POST,
                    "/v1.51/containers/compose-replacement-123/rename?name=unused"
                ) {
                    #expect($0.status == .notFound)
                }
                let occupiedID = DockerContainerID.hexId(for: occupied)
                try await app.testing().test(
                    .POST,
                    "/v1.51/containers/\(occupiedID)/rename?name=compose-replacement-123"
                ) {
                    #expect($0.status == .noContent)
                }
            })

    }

    @Test("invalid and missing names use Docker-compatible status codes")
    func validation() async throws {
        let metadataStore = DockerContainerMetadataStore()
        let snapshot = renameSnapshot("existing")

        try await withApp(
            configure: { _ in },
            { app in
                let router = app.regexRouter(with: app.logger)
                app.setRegexRouter(router)
                router.installMiddleware(on: app)
                app.middleware.use(DockerErrorMiddleware())
                try app.register(
                    collection: ContainerRenameRoute(
                        client: RenameClient(snapshots: [snapshot]),
                        metadataStore: metadataStore
                    )
                )
                try await app.testing().test(.POST, "/v1.51/containers/existing/rename?name=bad%20name") {
                    #expect($0.status == .badRequest)
                }
                try await app.testing().test(.POST, "/v1.51/containers/missing/rename?name=valid") {
                    #expect($0.status == .notFound)
                }
            })
    }

    @Test("renaming to the current name is a Docker bad request")
    func sameName() async throws {
        let metadataStore = DockerContainerMetadataStore()
        let snapshot = renameSnapshot("native-id")
        try await metadataStore.set(
            nativeID: snapshot.id,
            name: "postgres",
            publishedPorts: []
        )

        try await withApp(
            configure: { _ in },
            { app in
                let router = app.regexRouter(with: app.logger)
                app.setRegexRouter(router)
                router.installMiddleware(on: app)
                app.middleware.use(DockerErrorMiddleware())
                try app.register(
                    collection: ContainerRenameRoute(
                        client: RenameClient(
                            snapshots: [snapshot],
                            metadataStore: metadataStore
                        ),
                        metadataStore: metadataStore
                    )
                )
                try await app.testing().test(
                    .POST,
                    "/v1.51/containers/postgres/rename?name=postgres"
                ) {
                    #expect($0.status == .badRequest)
                }
            })
    }

    @Test("running rename atomically transfers the primary DNS alias")
    func runningDNSRename() async throws {
        let metadataStore = DockerContainerMetadataStore()
        let snapshot = try makeContainerSnapshot(
            nativeId: "st-opaque",
            ip: "192.168.65.20",
            network: "compose_default",
            labels: [:],
            status: .running
        )
        try await metadataStore.set(
            nativeID: snapshot.id,
            name: "old-db",
            publishedPorts: []
        )
        let dnsServer = SocktainerDNSServer()
        dnsServer.register(hostname: "old-db", ip: "192.168.65.20")

        try await withApp(
            configure: { _ in },
            { app in
                let router = app.regexRouter(with: app.logger)
                app.setRegexRouter(router)
                router.installMiddleware(on: app)
                app.middleware.use(DockerErrorMiddleware())
                app.storage[SocktainerDNSServerKey.self] = dnsServer
                try app.register(
                    collection: ContainerRenameRoute(
                        client: RenameClient(
                            snapshots: [snapshot],
                            metadataStore: metadataStore
                        ),
                        metadataStore: metadataStore
                    )
                )
                try await app.testing().test(
                    .POST,
                    "/v1.51/containers/old-db/rename?name=new-db"
                ) {
                    #expect($0.status == .noContent)
                }
                try await app.testing().test(
                    .POST,
                    "/v1.51/containers/st-opaque/rename?name=must-not-resolve"
                ) {
                    #expect($0.status == .notFound)
                }
            })

        #expect(dnsServer.listEntries()["old-db"] == nil)
        #expect(dnsServer.listEntries()["new-db"] == "192.168.65.20")
    }
}
