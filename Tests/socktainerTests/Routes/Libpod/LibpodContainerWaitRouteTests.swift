import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Real podman's libpod `wait` endpoint (`condition=`, repeatable) uses the container's own
/// lowercase status names ("stopped", "exited", "running", "paused", "created", "configured"),
/// not Docker compat's `wait`-specific vocabulary (`ContainerWaitCondition`: "not-running",
/// "next-exit", "removed", "healthy") — passing a real podman condition straight to
/// `ContainerWaitCondition(rawValue:)` rejected every explicit condition a real `podman wait`
/// call would send.
@Suite("LibpodContainerWaitRoute — condition mapping")
struct LibpodContainerWaitRouteTests {
    @Test("condition=stopped (real podman's own vocabulary) maps to notRunning, not a 400")
    func stoppedConditionMapsToNotRunning() async throws {
        let client = RecordingWaitClient()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodContainerWaitRoute(client: client))

            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/wait?condition=stopped") { res async throws in
                #expect(res.status == .ok)
                // Podman's binding decodes the exit code as a bare JSON integer, not Docker's
                // `{"StatusCode": N}` object.
                #expect(String(buffer: res.body).trimmingCharacters(in: .whitespacesAndNewlines) == "0")
            }
        }
        #expect(await client.receivedCondition == .notRunning)
    }

    @Test("condition=removing (real podman's in-progress-removal status) maps to removed, not a 400")
    func removingConditionMapsToRemoved() async throws {
        let client = RecordingWaitClient()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodContainerWaitRoute(client: client))

            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/wait?condition=removing") { res async throws in
                #expect(res.status == .ok)
            }
        }
        #expect(await client.receivedCondition == .removed)
    }

    @Test("condition=running (not implemented) is 501, not a misleading 400 'invalid condition'")
    func runningConditionIsNotImplemented() async throws {
        let client = RecordingWaitClient()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodContainerWaitRoute(client: client))

            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/wait?condition=running") { res async throws in
                #expect(res.status == .notImplemented)
            }
        }
        #expect(await client.receivedCondition == nil)
    }
}

private actor RecordingWaitClient: ClientContainerProtocol {
    private(set) var receivedCondition: ContainerWaitCondition?

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { makeStoppedSnapshot() }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        receivedCondition = condition
        return RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

/// The Docker-compat wait handler (which this route delegates to) 404s on a container that doesn't exist.
private func makeStoppedSnapshot() -> ContainerSnapshot {
    let process = ProcessConfiguration(
        executable: "/bin/sh", arguments: [], environment: [], workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
    let image = ImageDescription(
        reference: "alpine:latest",
        descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
    let config = ContainerConfiguration(id: "ctr", image: image, process: process)
    return ContainerSnapshot(configuration: config, status: .stopped, networks: [])
}
