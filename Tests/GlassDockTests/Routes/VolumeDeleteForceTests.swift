import ContainerResource
import ContainerizationError
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import GlassDock

/// DELETE /volumes/{name} must follow the Docker Engine API force contract:
/// removing a volume that does not exist is a 404 ("no such volume") without
/// `force`, and a silent 204 no-op with `force=1`. moby inspects the volume
/// first, so a missing volume never reaches the delete call. The previous
/// implementation ignored `force` and let the not-found error surface as a 500.
///
/// The not-found error is exercised in both shapes it can reach the route as:
/// the framework's typed `VolumeError.volumeNotFound`, and the
/// `ContainerizationError` it is flattened into across Apple Container's XPC
/// boundary (the shape that actually reaches the route in production).
@Suite("VolumeDeleteRoute — force query parameter")
struct VolumeDeleteForceTests {

    /// How a missing volume surfaces from `client.inspect`.
    enum NotFound: CaseIterable, Sendable {
        case xpcFlattened  // production: ContainerizationError with a "not found" message
        case typed  // defensive: the framework's own VolumeError

        func error(_ name: String) -> any Error {
            switch self {
            case .xpcFlattened: return ContainerizationError(.invalidArgument, message: "volume '\(name)' not found")
            case .typed: return VolumeError.volumeNotFound(name)
            }
        }
    }

    @Test("Deleting an existing volume returns 204 and removes it")
    func existingVolumeDeletes() async throws {
        let log = CallLog()
        let mock = RecordingVolumeMock(existing: Self.volume(name: "pgdata"), notFound: .xpcFlattened, log: log)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: VolumeDeleteRoute(client: mock))

            try await app.testing().test(.DELETE, "/v1.51/volumes/pgdata") { res async in
                #expect(res.status == .noContent)
            }
        }

        let calls = await log.calls
        #expect(calls == ["delete"], "An existing volume is deleted")
    }

    @Test(
        "Deleting a missing volume without force returns 404 and performs no delete",
        arguments: NotFound.allCases)
    func missingWithoutForceIsNotFound(notFound: NotFound) async throws {
        let log = CallLog()
        let mock = RecordingVolumeMock(existing: nil, notFound: notFound, log: log)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: VolumeDeleteRoute(client: mock))

            try await app.testing().test(.DELETE, "/v1.51/volumes/ghost") { res async in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("no such volume"))
            }
        }

        let calls = await log.calls
        #expect(calls.isEmpty, "A missing volume must not reach the delete call")
    }

    @Test(
        "Deleting a missing volume with force returns 204 and performs no delete",
        arguments: ["force=1", "force=true"], NotFound.allCases)
    func missingWithForceIsNoOp(forceParam: String, notFound: NotFound) async throws {
        let log = CallLog()
        let mock = RecordingVolumeMock(existing: nil, notFound: notFound, log: log)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: VolumeDeleteRoute(client: mock))

            try await app.testing().test(.DELETE, "/v1.51/volumes/ghost?\(forceParam)") { res async in
                #expect(res.status == .noContent)
            }
        }

        let calls = await log.calls
        #expect(calls.isEmpty, "force purges a missing volume silently, without a delete call")
    }

    @Test(
        "A volume that vanishes between inspect and delete is a 404 without force",
        arguments: NotFound.allCases)
    func deleteRaceWithoutForceIsNotFound(notFound: NotFound) async throws {
        let log = CallLog()
        // inspect succeeds, but the delete then hits the not-found shape.
        let mock = RecordingVolumeMock(
            existing: Self.volume(name: "pgdata"), notFound: notFound, log: log, deleteError: notFound.error("pgdata"))

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: VolumeDeleteRoute(client: mock))

            try await app.testing().test(.DELETE, "/v1.51/volumes/pgdata") { res async in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("no such volume"))
            }
        }

        let calls = await log.calls
        #expect(calls == ["delete"], "the delete was attempted before the race was detected")
    }

    @Test(
        "A volume that vanishes between inspect and delete is a silent 204 with force",
        arguments: NotFound.allCases)
    func deleteRaceWithForceIsNoOp(notFound: NotFound) async throws {
        let log = CallLog()
        let mock = RecordingVolumeMock(
            existing: Self.volume(name: "pgdata"), notFound: notFound, log: log, deleteError: notFound.error("pgdata"))

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: VolumeDeleteRoute(client: mock))

            try await app.testing().test(.DELETE, "/v1.51/volumes/pgdata?force=1") { res async in
                #expect(res.status == .noContent)
            }
        }

        let calls = await log.calls
        #expect(calls == ["delete"], "force swallows the race after the delete attempt")
    }

    // MARK: - Helpers

    private static func volume(name: String, driver: String = "local") -> Volume {
        Volume(
            Name: name, Driver: driver, Mountpoint: "/tmp/\(name)", CreatedAt: nil,
            Status: nil, Labels: nil, Scope: "local", ClusterVolume: nil,
            Options: [:], UsageData: nil)
    }
}

// MARK: - Mocks

private actor CallLog {
    var calls: [String] = []
    func add(_ call: String) { calls.append(call) }
}

/// Mock backing a single volume (or none). When the volume is absent, `inspect`
/// throws the requested not-found shape, mirroring what `ClientVolume` surfaces.
private struct RecordingVolumeMock: ClientVolumeProtocol {
    let existing: Volume?
    let notFound: VolumeDeleteForceTests.NotFound
    let log: CallLog
    /// When set, `delete` throws this after logging, simulating a volume that
    /// vanished between the route's inspect and its delete call.
    var deleteError: (any Error)?

    func create(request: RESTVolumeCreate) async throws -> Volume {
        throw VolumeError.storageError("not used")
    }
    func delete(name: String) async throws {
        await log.add("delete")
        if let deleteError { throw deleteError }
    }
    func list(filters: String?, logger: Logger) async throws -> [Volume] {
        existing.map { [$0] } ?? []
    }
    func inspect(name: String) async throws -> Volume {
        guard let existing else { throw notFound.error(name) }
        return existing
    }
}
