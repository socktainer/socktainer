import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// moby emits per-volume "mount" events while setting up mounts at container start
/// (daemon/volumes_unix.go) and "unmount" during exit cleanup, before "die"
/// (container.UnmountVolumes). The die event also carries execDuration in whole
/// seconds (daemon/monitor.go).
@Suite("Volume mount/unmount events & die execDuration")
struct VolumeMountEventTests {

    @Test("/start broadcasts a 'mount' per named volume with moby's attributes")
    func startEmitsMountPerVolume() async throws {
        let nativeId = "mount-ctr-\(Int.random(in: 10000...99999))"
        let snapshot = makeMountedSnapshot(nativeId: nativeId, readonly: false)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "mount" { return event }
            return nil
        }

        await ContainerExitCodeStore.shared.remove(id: nativeId)

        try await withStartApp(snapshot: snapshot, broadcaster: broadcaster) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()
        await releaseDieObserver(nativeId: nativeId)

        #expect(event?.Type == "volume")
        #expect(event?.Actor.ID == "pgdata")
        #expect(event?.Actor.Attributes["driver"] == "local")
        #expect(event?.Actor.Attributes["container"] == DockerContainerID.hexId(for: snapshot))
        #expect(event?.Actor.Attributes["destination"] == "/var/lib/postgresql/data")
        #expect(event?.Actor.Attributes["read/write"] == "true")
        #expect(event?.Actor.Attributes["propagation"] == "")
    }

    @Test("a read-only volume mount reports read/write=false")
    func readOnlyMountReportsFalse() async throws {
        let nativeId = "mount-ro-\(Int.random(in: 10000...99999))"
        let snapshot = makeMountedSnapshot(nativeId: nativeId, readonly: true)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "mount" { return event }
            return nil
        }

        await ContainerExitCodeStore.shared.remove(id: nativeId)

        try await withStartApp(snapshot: snapshot, broadcaster: broadcaster) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()
        await releaseDieObserver(nativeId: nativeId)

        #expect(event?.Actor.Attributes["read/write"] == "false")
    }

    @Test("a container without volume mounts broadcasts no 'mount'")
    func noVolumesNoMountEvent() async throws {
        let nativeId = "mount-none-\(Int.random(in: 10000...99999))"
        let snapshot = makeMountedSnapshot(nativeId: nativeId, readonly: false, includeVolume: false)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "mount" { return event }
            return nil
        }

        await ContainerExitCodeStore.shared.remove(id: nativeId)

        try await withStartApp(snapshot: snapshot, broadcaster: broadcaster) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        let event = await withTimeout(captureTask)
        captureTask.cancel()
        await releaseDieObserver(nativeId: nativeId)
        #expect(event == nil)
    }

    @Test("the exit observer broadcasts 'unmount' before 'die', and die carries execDuration")
    func exitEmitsUnmountThenDieWithExecDuration() async throws {
        let nativeId = "unmount-ctr-\(Int.random(in: 10000...99999))"
        let snapshot = makeMountedSnapshot(nativeId: nativeId, readonly: false)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let captureTask = Task<[DockerEvent], Never> {
            var events: [DockerEvent] = []
            for await event in stream where event.Action == "unmount" || event.Action == "die" {
                events.append(event)
                if events.count == 2 { return events }
            }
            return events
        }

        await ContainerExitCodeStore.shared.remove(id: nativeId)

        try await withStartApp(snapshot: snapshot, broadcaster: broadcaster) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        await ContainerExitCodeStore.shared.set(id: nativeId, code: 7)

        let events = await withTimeout(captureTask)
        captureTask.cancel()
        await ContainerExitCodeStore.shared.remove(id: nativeId)

        #expect(events.count == 2)
        #expect(events.first?.Action == "unmount")
        #expect(events.first?.Type == "volume")
        #expect(events.first?.Actor.ID == "pgdata")
        #expect(events.first?.Actor.Attributes["driver"] == "local")
        #expect(events.first?.Actor.Attributes["container"] == DockerContainerID.hexId(for: snapshot))

        let die = events.last
        #expect(die?.Action == "die")
        #expect(die?.Actor.Attributes["exitCode"] == "7")
        let execDuration = die?.Actor.Attributes["execDuration"].flatMap(Int.init)
        #expect(execDuration != nil && execDuration! >= 0)
    }
}

// MARK: - Helpers

private func withStartApp(
    snapshot: ContainerSnapshot,
    broadcaster: EventBroadcaster,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = broadcaster
        try app.register(collection: ContainerStartRoute(client: StaticSnapshotClientMock(snapshot: snapshot)))
        try await test(app)
    }
}

/// Releases the detached die observer /start armed for this container so its
/// waiter does not leak into later tests.
private func releaseDieObserver(nativeId: String) async {
    await ContainerExitCodeStore.shared.set(id: nativeId, code: 0)
    await ContainerExitCodeStore.shared.remove(id: nativeId)
}

private func withTimeout<T>(_ task: Task<T, Never>) async -> T {
    let timeout = Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        task.cancel()
    }
    let value = await task.value
    timeout.cancel()
    return value
}

private func makeMountedSnapshot(nativeId: String, readonly: Bool, includeVolume: Bool = true) -> ContainerSnapshot {
    let proc = ProcessConfiguration(
        executable: "/bin/sh", arguments: [], environment: [],
        workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
    )
    let img = ImageDescription(
        reference: "postgres:16",
        descriptor: Descriptor(
            mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
    )
    var config = ContainerConfiguration(id: nativeId, image: img, process: proc)
    var mounts: [Filesystem] = [
        .virtiofs(source: "/tmp/host-dir", destination: "/mnt/host", options: [])
    ]
    if includeVolume {
        mounts.append(
            .volume(
                name: "pgdata",
                format: "ext4",
                source: "/var/lib/volumes/pgdata",
                destination: "/var/lib/postgresql/data",
                options: readonly ? ["ro"] : []
            ))
    }
    config.mounts = mounts
    return ContainerSnapshot(configuration: config, status: .stopped, networks: [])
}
