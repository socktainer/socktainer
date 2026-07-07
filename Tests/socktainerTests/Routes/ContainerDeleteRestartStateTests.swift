import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression test: deleting a container used to leave its `ContainerRestartState` entry
/// behind, so a new container recreated under the same name (the common `docker rm && docker
/// run` / Compose recreate cycle) would inherit the deleted container's restart-attempt count
/// — showing a nonzero `RestartCount` immediately and skewing `on-failure` max-retry counting.
@Suite("ContainerDeleteRoute — restart-state cleanup")
struct ContainerDeleteRestartStateTests {

    @Test("Deleting a container clears its ContainerRestartState entry")
    func deleteClearsRestartState() async throws {
        let nativeId = "delete-restart-state-ctr"
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

        _ = await ContainerRestartState.shared.nextAttempt(id: nativeId)
        _ = await ContainerRestartState.shared.nextAttempt(id: nativeId)
        #expect(await ContainerRestartState.shared.count(id: nativeId) == 2)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerDeleteRoute(client: DeleteMock(snapshot: snapshot)))

            try await app.testing().test(.DELETE, "/v1.51/containers/\(nativeId)") { res async in
                #expect(res.status == .noContent)
            }
        }

        #expect(await ContainerRestartState.shared.count(id: nativeId) == 0, "restart-attempt count must not survive delete")
    }
}

private struct DeleteMock: ClientContainerProtocol {
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
