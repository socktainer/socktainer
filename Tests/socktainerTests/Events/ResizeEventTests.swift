import ContainerAPIClient
import ContainerResource
import ContainerizationOS
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// moby emits "resize" only after a successful container TTY resize, with the requested
/// height/width as decimal-string attributes (daemon/resize.go). Exec resize emits nothing.
@Suite("Resize events")
struct ResizeEventTests {

    @Test("a successful container resize broadcasts 'resize' with height/width attributes")
    func containerResizeEmitsEvent() async throws {
        let nativeId = "resize-ctr-\(Int.random(in: 10000...99999))"
        let snapshot = try makeContainerSnapshot(nativeId: nativeId, ip: "192.168.65.2", network: "bridge", labels: ["app": "tty"], status: .running)
        await ProcessRegistry.shared.set(id: nativeId, process: RecordingProcess(failResize: false))
        defer { Task { await ProcessRegistry.shared.remove(id: nativeId) } }

        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "resize" { return event }
            return nil
        }

        try await withResizeApp(snapshot: snapshot, broadcaster: broadcaster) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/resize?h=40&w=120") { res async in
                #expect(res.status == .ok)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()

        #expect(event?.Type == "container")
        #expect(event?.Actor.ID == DockerContainerID.hexId(for: snapshot))
        #expect(event?.Actor.Attributes["height"] == "40")
        #expect(event?.Actor.Attributes["width"] == "120")
        #expect(event?.Actor.Attributes["app"] == "tty")
    }

    @Test("a failed resize broadcasts nothing")
    func failedResizeStaysSilent() async throws {
        let nativeId = "resize-fail-\(Int.random(in: 10000...99999))"
        let snapshot = try makeContainerSnapshot(nativeId: nativeId, ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        await ProcessRegistry.shared.set(id: nativeId, process: RecordingProcess(failResize: true))
        defer { Task { await ProcessRegistry.shared.remove(id: nativeId) } }

        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "resize" { return event }
            return nil
        }

        try await withResizeApp(snapshot: snapshot, broadcaster: broadcaster) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/resize?h=40&w=120") { res async in
                #expect(res.status == .ok)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()
        #expect(event == nil)
    }

    @Test("a container with no running process broadcasts nothing")
    func noProcessStaysSilent() async throws {
        let nativeId = "resize-none-\(Int.random(in: 10000...99999))"
        let snapshot = try makeContainerSnapshot(nativeId: nativeId, ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)

        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "resize" { return event }
            return nil
        }

        try await withResizeApp(snapshot: snapshot, broadcaster: broadcaster) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/resize?h=40&w=120") { res async in
                #expect(res.status == .ok)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()
        #expect(event == nil)
    }

    @Test("a successful exec resize broadcasts nothing, like moby")
    func execResizeStaysSilent() async throws {
        let execId = await ExecManager.shared.create(
            config: ExecManager.ExecConfig(
                containerId: "resize-exec-ctr", cmd: ["sh"],
                attachStdin: false, attachStdout: true, attachStderr: true,
                tty: true, detach: false, env: [], user: nil, workingDir: nil
            ))
        await ProcessRegistry.shared.set(id: execId, process: RecordingProcess(failResize: false))
        defer {
            Task {
                await ProcessRegistry.shared.remove(id: execId)
                await ExecManager.shared.remove(id: execId)
            }
        }

        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "resize" { return event }
            return nil
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ExecRoute(client: StubClientMock()))

            try await app.testing().test(.POST, "/v1.51/exec/\(execId)/resize?h=40&w=120") { res async in
                #expect(res.status == .ok)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()
        #expect(event == nil)
    }
}

// MARK: - Helpers

private func withResizeApp(
    snapshot: ContainerSnapshot,
    broadcaster: EventBroadcaster,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = broadcaster
        try app.register(collection: ContainerResizeRoute(client: StaticSnapshotClientMock(snapshot: snapshot)))
        try await test(app)
    }
}

private func withTimeout<T>(_ task: Task<T, Never>) async -> T {
    let timeout = Task {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        task.cancel()
    }
    let value = await task.value
    timeout.cancel()
    return value
}

private struct RecordingProcess: ClientProcess {
    let id = "resize-test-process"
    let failResize: Bool
    func start() async throws {}
    func resize(_ size: ContainerizationOS.Terminal.Size) async throws {
        if failResize { throw Abort(.internalServerError, reason: "resize failed") }
    }
    func kill(_ signal: Int32) async throws {}
    func wait() async throws -> Int32 { 0 }
}

private struct StubClientMock: ClientContainerProtocol {
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
