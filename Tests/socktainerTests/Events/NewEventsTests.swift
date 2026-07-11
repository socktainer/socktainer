import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Tests for new Docker events added for issue #90 parity.
/// Routes that store concrete service types (volume/network prune build their
/// service internally) are covered by integration tests; these cover routes
/// that accept a protocol.
@Suite("New events — issue #90 parity")
struct NewEventsTests {

    // MARK: - network.create

    @Test("network create route broadcasts Type=network Action=create event")
    func networkCreateEventBroadcast() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "create" && event.Type == "network" { return event }
            return nil
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: NetworkCreateRoute(client: StubNetworkClient()))

            try await app.testing().test(
                .POST, "/v1.51/networks/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"my-net"}"#)
            ) { res async in
                #expect(res.status == .created)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()

        #expect(event?.Type == "network")
        #expect(event?.Action == "create")
        #expect(event?.Actor.ID == "net-abc123")
        #expect(event?.Actor.Attributes["name"] == "my-net")
        #expect(event?.Actor.Attributes["type"] == "nat", "moby network events carry a 'type' attribute")
        #expect(event?.Actor.Attributes["image"] == nil, "network events carry no 'image' attribute")
    }

    // MARK: - network.destroy

    @Test("network delete route broadcasts Type=network Action=destroy event")
    func networkDestroyEventBroadcast() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "destroy" && event.Type == "network" { return event }
            return nil
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: NetworkDeleteRoute(client: StubNetworkClient()))

            try await app.testing().test(.DELETE, "/v1.51/networks/net-abc123") { res async in
                #expect(res.status == .noContent)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()

        #expect(event?.Type == "network")
        #expect(event?.Action == "destroy")
        #expect(event?.Actor.ID == "net-abc123")
        // name/type captured from getNetwork before deletion (StubNetworkClient returns these).
        #expect(event?.Actor.Attributes["name"] == "my-network")
        #expect(event?.Actor.Attributes["type"] == "nat")
        #expect(event?.Actor.Attributes["image"] == nil)
    }

    // MARK: - container.prune

    @Test("container prune route broadcasts Type=container Action=prune event")
    func containerPruneEventBroadcast() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "prune" && event.Type == "container" { return event }
            return nil
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerPruneRoute(client: StubContainerClient()))

            try await app.testing().test(.POST, "/v1.51/containers/prune") { res async in
                #expect(res.status == .ok)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()

        #expect(event?.Type == "container")
        #expect(event?.Action == "prune")
        // moby prune events: empty Actor.ID, only a `reclaimed` attribute.
        #expect(event?.Actor.ID == "")
        #expect(event?.Actor.Attributes["reclaimed"] == "1024")
        #expect(event?.Actor.Attributes["name"] == nil, "prune events carry no 'name' attribute")
        #expect(event?.Actor.Attributes["image"] == nil, "prune events carry no 'image' attribute")
    }

    @Test("container prune emits a per-container 'destroy' before the aggregate prune")
    func containerPruneEmitsPerContainerDestroy() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        // Collect both the destroy and the aggregate prune to assert ordering/coexistence.
        let captureTask = Task<[DockerEvent], Never> {
            var collected: [DockerEvent] = []
            for await event in stream where event.Type == "container" {
                collected.append(event)
                if event.Action == "prune" { break }
            }
            return collected
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerPruneRoute(client: StubContainerClient()))

            try await app.testing().test(.POST, "/v1.51/containers/prune") { res async in
                #expect(res.status == .ok)
            }
        }

        let events = await withTimeout(captureTask)
        captureTask.cancel()

        let destroy = events.first { $0.Action == "destroy" }
        let prune = events.first { $0.Action == "prune" }
        // moby fires a `destroy` per removed container (StubContainerClient prunes "my-container")…
        #expect(destroy != nil, "container prune must emit a per-container destroy")
        #expect(destroy?.Actor.ID == "my-container")
        // …then the aggregate prune, and the destroy must precede it.
        #expect(prune != nil)
        if let di = events.firstIndex(where: { $0.Action == "destroy" }),
            let pi = events.firstIndex(where: { $0.Action == "prune" })
        {
            #expect(di < pi, "destroy must precede the aggregate prune")
        }
    }

    // MARK: - container.kill

    @Test("kill route broadcasts a 'kill' event carrying the numeric signal attribute")
    func killEventCarriesSignal() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "kill" && event.Type == "container" { return event }
            return nil
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerKillRoute(client: StubContainerClient()))

            try await app.testing().test(.POST, "/v1.51/containers/my-container/kill?signal=SIGTERM") { res async in
                #expect(res.status == .noContent)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()

        #expect(event?.Action == "kill")
        // moby's kill event carries the numeric signal (SIGTERM == 15).
        #expect(event?.Actor.Attributes["signal"] == String(SIGTERM))
    }

    @Test("kill route defaults the signal attribute to SIGKILL when none is given")
    func killEventDefaultsToSigkill() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "kill" && event.Type == "container" { return event }
            return nil
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerKillRoute(client: StubContainerClient()))

            try await app.testing().test(.POST, "/v1.51/containers/my-container/kill") { res async in
                #expect(res.status == .noContent)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()

        #expect(event?.Actor.Attributes["signal"] == String(SIGKILL), "Docker defaults kill to SIGKILL")
    }

    // MARK: - image.prune

    // moby's image prune emits per-image `untag`/`delete` events — NOT an aggregate "prune"
    // event (that exists for containers/networks/volumes, but not images). Verified against
    // moby v28.5.2 daemon/containerd/image_prune.go.
    @Test("image prune route emits per-image untag/delete, never an aggregate 'prune'")
    func imagePruneEventBroadcast() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<[DockerEvent], Never> {
            var collected: [DockerEvent] = []
            for await event in stream where event.Type == "image" {
                collected.append(event)
                if collected.contains(where: { $0.Action == "untag" })
                    && collected.contains(where: { $0.Action == "delete" })
                {
                    return collected
                }
            }
            return collected
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ImagePruneRoute(client: StubImageClient()))

            try await app.testing().test(.POST, "/v1.51/images/prune") { res async in
                #expect(res.status == .ok)
            }
        }

        let timeout = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            captureTask.cancel()
        }
        let events = await captureTask.value
        timeout.cancel()

        // untag: Actor.ID = digest, name = the removed reference.
        let untag = events.first { $0.Action == "untag" }
        #expect(untag?.Type == "image")
        #expect(untag?.Actor.ID == "sha256:abc123")
        #expect(untag?.Actor.Attributes["name"] == "docker.io/library/alpine:latest")
        // delete: Actor.ID = freed digest.
        let del = events.first { $0.Action == "delete" }
        #expect(del?.Type == "image")
        #expect(del?.Actor.ID == "sha256:abc123")
        // The spurious aggregate prune event must be gone.
        #expect(!events.contains { $0.Action == "prune" }, "image prune must not emit an aggregate 'prune' event")
    }

    // MARK: - container.die

    @Test("start route fires 'die' event with the recorded exitCode after the container exits")
    func containerDieEventBroadcast() async throws {
        let nativeId = "die-ctr-\(Int.random(in: 10000...99999))"
        // .stopped so the start route actually starts it (and spawns the die observer).
        let snapshot = makeContainerSnapshot(nativeId: nativeId, image: "alpine:latest", labels: [:], status: .stopped)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "die" { return event }
            return nil
        }

        // Clean slate, then simulate the start() background recorder writing the real exit
        // code: the die observer awaits ContainerExitCodeStore, so set(42) must resolve it.
        await ContainerExitCodeStore.shared.remove(id: nativeId)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerStartRoute(client: DieAfterStartMock(snapshot: snapshot, exitCode: 42)))

            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        // Recorder writes the authoritative code → resumes the die observer's waitForCode.
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 42)

        let event = await withTimeout(captureTask)
        captureTask.cancel()
        await ContainerExitCodeStore.shared.remove(id: nativeId)

        #expect(event?.Type == "container")
        #expect(event?.Action == "die")
        #expect(event?.Actor.Attributes["exitCode"] == "42")
    }

    @Test("/start emits a start event even when the snapshot already shows running")
    func startEmittedForAlreadyRunningSnapshot() async throws {
        // For a foreground `docker run`, the attach route bootstraps and starts the container
        // before /start is called, so /start sees it already running. The start event must
        // still fire (we don't gate on a not-running→running transition), otherwise the common
        // `docker run` case loses its start event.
        let nativeId = "running-ctr"
        let snapshot = makeContainerSnapshot(nativeId: nativeId, image: "alpine:latest", labels: ["app": "fg"], status: .running)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "start" && event.Type == "container" { return event }
            return nil
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: ContainerStartRoute(client: DieAfterStartMock(snapshot: snapshot, exitCode: 0)))

            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()

        #expect(event?.Action == "start")
        #expect(event?.Actor.Attributes["app"] == "fg")

        // Release the detached die observer /start spawned for this snapshot (it awaits
        // ContainerExitCodeStore for nativeId); otherwise a waiter/task leaks into later tests.
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 0)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }
}

// MARK: - Helpers

/// Awaits the capture task's event, bounded by a timeout. After the timeout the
/// capture task is cancelled so its `for await` loop exits and returns nil — this
/// is essential for negative tests (expecting no event), where the event never
/// arrives and awaiting the task directly would block forever.
private func withTimeout<T>(_ task: Task<T, Never>) async -> T {
    let timeout = Task {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        task.cancel()
    }
    let value = await task.value
    timeout.cancel()
    return value
}

private func makeContainerSnapshot(
    nativeId: String, image: String, labels: [String: String], status: RuntimeStatus = .running
) -> ContainerSnapshot {
    let proc = ProcessConfiguration(
        executable: "/bin/sh", arguments: [], environment: [],
        workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
    )
    let img = ImageDescription(
        reference: image,
        descriptor: Descriptor(
            mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
    )
    var config = ContainerConfiguration(id: nativeId, image: img, process: proc)
    config.labels = labels
    return ContainerSnapshot(configuration: config, status: status, networks: [])
}

private struct DieAfterStartMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot
    let exitCode: Int64
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: exitCode)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

private struct StubContainerClient: ClientContainerProtocol {
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
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        (["my-container"], 1024)
    }
}

private struct StubImageClient: ClientImageProtocol {
    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult {
        ImageDeletionResult(untagged: id, digest: "sha256:abc", deletedDigest: nil)
    }
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws
        -> AsyncThrowingStream<PullProgress, Error>
    {
        AsyncThrowingStream { $0.finish() }
    }
    func push(reference: String, platform: Platform?, logger: Logger) async throws
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { $0.finish() }
    }
    func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
        (
            [ImageDeletionResult(untagged: "docker.io/library/alpine:latest", digest: "sha256:abc123", deletedDigest: "sha256:abc123")],
            5_000_000
        )
    }
    func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] { [] }
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        URL(fileURLWithPath: "/tmp")
    }
}

private struct StubNetworkClient: ClientNetworkProtocol {
    func list(filters: String?, logger: Logger) async throws -> [RESTNetworkSummary] { [] }
    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary? {
        RESTNetworkSummary(
            Name: "my-network", Id: id, Created: "", Scope: "local", Driver: "nat",
            EnableIPv4: true, EnableIPv6: false, Internal: false, Attachable: false, Ingress: false,
            IPAM: NetworkIPAM(Driver: "", Config: []), Options: [:], Containers: nil,
            ConfigFrom: nil, Labels: [:], Subnet: nil, Gateway: nil)
    }
    func create(name: String, labels: [String: String], ipv4Subnet: String?, logger: Logger) async throws -> RESTNetworkCreate {
        RESTNetworkCreate(Id: "net-abc123", Warning: "")
    }
    func delete(id: String, logger: Logger) async throws {}
}
