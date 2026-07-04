import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// POST /containers/{id}/exec must reject an empty Cmd at create time, as
/// Docker does. Without the guard the empty command is stored and the later
/// exec start force-unwraps `cmd.first!`, crashing the whole daemon.
@Suite("ExecRoute — create Cmd validation")
struct ExecCreateRouteTests {

    @Test(
        "Empty or missing Cmd returns 400 with Docker's message",
        arguments: [#"{"Cmd":[]}"#, "{}"])
    func emptyCmdReturns400(payload: String) async throws {
        try await withRunningContainerApp { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/running-ctr/exec",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: payload)
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("No exec command specified"))
            }
        }
    }

    @Test("Non-empty Cmd still creates the exec instance")
    func nonEmptyCmdCreates() async throws {
        try await withRunningContainerApp { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/running-ctr/exec",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Cmd":["echo","hi"]}"#)
            ) { res async throws in
                #expect(res.status == .created)
                let created = try JSONDecoder().decode(CreateExecResponse.self, from: Data(buffer: res.body))
                #expect(!created.Id.isEmpty)
                // The stored config carries the command through to exec start.
                let stored = await ExecManager.shared.get(id: created.Id)
                #expect(stored?.cmd == ["echo", "hi"])
                await ExecManager.shared.remove(id: created.Id)
            }
        }
    }
}

// MARK: - Helpers

private func withRunningContainerApp(
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = EventBroadcaster()
        try app.register(collection: ExecRoute(client: RunningContainerMock()))
        try await test(app)
    }
}

/// Mock whose getContainer always returns a running snapshot, so createExec
/// reaches the request-body validation.
private struct RunningContainerMock: ClientContainerProtocol {
    private var snapshot: ContainerSnapshot {
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
        let config = ContainerConfiguration(id: "running-ctr", image: img, process: proc)
        return ContainerSnapshot(configuration: config, status: .running, networks: [])
    }
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
