import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("ContainerStartRoute — event label forwarding")
struct ContainerStartEventLabelTests {

    @Test("Start event Actor.Attributes carries container labels, image, and name")
    func startEventCarriesLabels() async throws {
        let hexId = "aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa1111bbbb2222"
        let nativeId = "my-labeled-container"
        let snapshot = makeSnapshot(nativeId: nativeId, labels: ["app": "myapp", "env": "prod"])
        let broadcaster = EventBroadcaster()

        // Subscribe before the route fires so the buffered event is not missed.
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "start" {
                return event
            }
            return nil
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerStartRoute(client: StartMock(snapshot: snapshot)))

            try await app.testing().test(.POST, "/v1.51/containers/\(hexId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        // The route awaited broadcaster.broadcast() before returning, so the event is
        // already in the stream buffer. captureTask picks it up on its next iteration.
        captureTask.cancel()  // unblock the for-await after we take the value
        let event = await captureTask.value

        let attrs = event?.Actor.Attributes
        #expect(attrs?["app"] == "myapp")
        #expect(attrs?["env"] == "prod")
        #expect(attrs?["image"] == "alpine:latest")
        #expect(attrs?["name"] == nativeId)
    }
}

// MARK: - Helpers

private func makeSnapshot(nativeId: String, labels: [String: String]) -> ContainerSnapshot {
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
    var config = ContainerConfiguration(id: nativeId, image: img, process: proc)
    config.labels = labels
    return ContainerSnapshot(configuration: config, status: .stopped, networks: [])
}

private struct StartMock: ClientContainerProtocol {
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
