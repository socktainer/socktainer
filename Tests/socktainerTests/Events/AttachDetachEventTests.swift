import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Attach/detach/exec_detach emission decisions, extracted from the streaming plumbing
/// so moby's gating (daemon/attach.go, daemon/exec.go) is unit-testable: attach fires
/// for streaming and logs-only attaches alike; detach fires only when the client leaves
/// a still-running process, never when the process's own exit ended the attach.
@Suite("Attach/detach/exec_detach events")
struct AttachDetachEventTests {

    @Test("attach is broadcast for a streaming attach on a running container")
    func attachEmittedForStreamingAttach() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: ["app": "web"], status: .running)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        await ContainerAttachRoute.broadcastAttach(container: snapshot, stream: true, logs: false, broadcaster: broadcaster)

        let events = await drainUntilSentinel(stream, broadcaster: broadcaster)
        #expect(events.count == 1)
        #expect(events.first?.Action == "attach")
        #expect(events.first?.Type == "container")
        #expect(events.first?.Actor.ID == DockerContainerID.hexId(for: snapshot))
        #expect(events.first?.Actor.Attributes["name"] == "web")
        #expect(events.first?.Actor.Attributes["app"] == "web")
    }

    @Test("attach is broadcast for a logs-only attach, like moby")
    func attachEmittedForLogsOnlyAttach() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        await ContainerAttachRoute.broadcastAttach(container: snapshot, stream: false, logs: true, broadcaster: broadcaster)

        let events = await drainUntilSentinel(stream, broadcaster: broadcaster)
        #expect(events.count == 1)
        #expect(events.first?.Action == "attach")
    }

    @Test("attach is silent when the container lookup failed")
    func attachSilentWhenLookupFailed() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        await ContainerAttachRoute.broadcastAttach(container: nil, stream: true, logs: true, broadcaster: broadcaster)

        let events = await drainUntilSentinel(stream, broadcaster: broadcaster)
        #expect(events.isEmpty)
    }

    @Test("attach is silent when neither stream nor logs was requested")
    func attachSilentWithoutStreamOrLogs() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        await ContainerAttachRoute.broadcastAttach(container: snapshot, stream: false, logs: false, broadcaster: broadcaster)

        let events = await drainUntilSentinel(stream, broadcaster: broadcaster)
        #expect(events.isEmpty)
    }

    @Test("POST /containers/{id}/attach on an unknown container returns 404 and broadcasts nothing")
    func attachRouteSilentOnUnknownContainer() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerAttachRoute(client: EmptyClientMock()))

            try await app.testing().test(.POST, "/v1.51/containers/ghost/attach?stream=1&stdout=1") { res async in
                #expect(res.status == .notFound)
            }
        }

        let events = await drainUntilSentinel(stream, broadcaster: broadcaster)
        #expect(events.isEmpty)
    }

    @Test("log-path detach fires when the client leaves a still-running container")
    func logDetachEmittedForRunningContainer() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        await ContainerAttachRoute.broadcastLogDetach(container: snapshot, stream: true, currentStatus: .running, broadcaster: broadcaster)

        let events = await drainUntilSentinel(stream, broadcaster: broadcaster)
        #expect(events.count == 1)
        #expect(events.first?.Action == "detach")
        #expect(events.first?.Actor.ID == DockerContainerID.hexId(for: snapshot))
    }

    @Test("log-path detach is silent when the container already exited")
    func logDetachSilentWhenContainerExited() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        await ContainerAttachRoute.broadcastLogDetach(container: snapshot, stream: true, currentStatus: .stopped, broadcaster: broadcaster)
        await ContainerAttachRoute.broadcastLogDetach(container: snapshot, stream: true, currentStatus: nil, broadcaster: broadcaster)

        let events = await drainUntilSentinel(stream, broadcaster: broadcaster)
        #expect(events.isEmpty)
    }

    @Test("log-path detach is silent for a logs-only attach")
    func logDetachSilentForLogsOnlyAttach() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        await ContainerAttachRoute.broadcastLogDetach(container: snapshot, stream: false, currentStatus: .running, broadcaster: broadcaster)

        let events = await drainUntilSentinel(stream, broadcaster: broadcaster)
        #expect(events.isEmpty)
    }

    @Test("interactive detach fires when the channel died with no exit code recorded")
    func interactiveDetachEmittedForClientDisconnect() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        await ContainerAttachRoute.broadcastInteractiveDetach(container: snapshot, channelActive: false, recordedExitCode: nil, broadcaster: broadcaster)

        let events = await drainUntilSentinel(stream, broadcaster: broadcaster)
        #expect(events.count == 1)
        #expect(events.first?.Action == "detach")
    }

    @Test("interactive detach is silent when the process exit closed the connection")
    func interactiveDetachSilentAfterProcessExit() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        await ContainerAttachRoute.broadcastInteractiveDetach(container: snapshot, channelActive: false, recordedExitCode: 0, broadcaster: broadcaster)
        await ContainerAttachRoute.broadcastInteractiveDetach(container: snapshot, channelActive: false, recordedExitCode: 137, broadcaster: broadcaster)

        let events = await drainUntilSentinel(stream, broadcaster: broadcaster)
        #expect(events.isEmpty)
    }

    @Test("interactive detach is silent while the channel is still active")
    func interactiveDetachSilentWhileChannelActive() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        await ContainerAttachRoute.broadcastInteractiveDetach(container: snapshot, channelActive: true, recordedExitCode: nil, broadcaster: broadcaster)

        let events = await drainUntilSentinel(stream, broadcaster: broadcaster)
        #expect(events.isEmpty)
    }

    @Test("exec_detach fires with a plain action and execID when the client detaches a running exec")
    func execDetachEmittedForRunningExec() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let execId = await ExecManager.shared.create(config: makeExecConfig())
        defer { Task { await ExecManager.shared.remove(id: execId) } }
        #expect(await ExecManager.shared.markStarted(id: execId))

        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        await ExecRoute.broadcastExecDetach(
            execRunning: await ExecManager.shared.isRunning(id: execId),
            execId: execId, container: snapshot, broadcaster: broadcaster
        )

        let events = await drainUntilSentinel(stream, broadcaster: broadcaster)
        #expect(events.count == 1)
        #expect(events.first?.Action == "exec_detach")
        #expect(events.first?.Actor.ID == DockerContainerID.hexId(for: snapshot))
        #expect(events.first?.Actor.Attributes["execID"] == execId)
    }

    @Test("exec_detach is silent once the exec's exit code was recorded")
    func execDetachSilentAfterProcessExit() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let execId = await ExecManager.shared.create(config: makeExecConfig())
        defer { Task { await ExecManager.shared.remove(id: execId) } }
        #expect(await ExecManager.shared.markStarted(id: execId))
        await ExecManager.shared.setExitCode(id: execId, code: 0)

        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        await ExecRoute.broadcastExecDetach(
            execRunning: await ExecManager.shared.isRunning(id: execId),
            execId: execId, container: snapshot, broadcaster: broadcaster
        )

        let events = await drainUntilSentinel(stream, broadcaster: broadcaster)
        #expect(events.isEmpty)
    }
}

// MARK: - Helpers

/// Deterministic capture without sleeps: every broadcast before the sentinel is already
/// buffered in the stream, so reading up to the sentinel yields exactly the events the
/// exercised code emitted.
private func drainUntilSentinel(_ stream: AsyncStream<DockerEvent>, broadcaster: EventBroadcaster) async -> [DockerEvent] {
    await broadcaster.broadcast(DockerEvent.make(type: "test", action: "sentinel", actorID: "sentinel", attributes: [:]))
    var events: [DockerEvent] = []
    for await event in stream {
        if event.Action == "sentinel" { break }
        events.append(event)
    }
    return events
}

private func makeExecConfig() -> ExecManager.ExecConfig {
    ExecManager.ExecConfig(
        containerId: "web", cmd: ["sh", "-c", "sleep 1"],
        attachStdin: true, attachStdout: true, attachStderr: false,
        tty: true, detach: false, env: [], user: nil, workingDir: nil
    )
}

private struct EmptyClientMock: ClientContainerProtocol {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
}
