import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression test: a generic (non-`ClientContainerError`) failure from `client.stop()` used to
/// propagate uncaught past the route's do/catch — Vapor's ErrorMiddleware still turns it into a
/// 500, but hides the real reason behind "Something went wrong." in release builds (the exact
/// shape observed live: `docker stop` on many containers during a crash returned only that
/// generic message, masking whatever the real underlying error was). The route must catch and
/// wrap any error into an `Abort` with a descriptive reason, matching the sibling start/kill/
/// restart routes, so the real failure is always visible to the client and in logs.
private struct GenericStopFailure: Error, CustomStringConvertible {
    var description: String { "synthetic VM teardown failure" }
}

private struct RouteErrorBody: Vapor.Content { let reason: String }

private struct StopFailureMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws { throw GenericStopFailure() }
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws { throw GenericStopFailure() }
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

private func makeSnapshot(id: String) -> ContainerSnapshot {
    let proc = ProcessConfiguration(
        executable: "/bin/sh", arguments: [], environment: [],
        workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
    )
    let img = ImageDescription(
        reference: "alpine:latest",
        descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
    )
    let config = ContainerConfiguration(id: id, image: img, process: proc)
    return ContainerSnapshot(configuration: config, status: .running, networks: [])
}

@Suite("ContainerStopRoute — generic error surfacing")
struct ContainerStopRouteGenericErrorTests {

    @Test("A non-ClientContainerError failure surfaces its real reason, not a generic message")
    func genericStopFailureSurfacesReason() async throws {
        let snapshot = makeSnapshot(id: "stop-fail-ctr")
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.middleware.use(ErrorMiddleware.default(environment: app.environment))
            try app.register(collection: ContainerStopRoute(client: StopFailureMock(snapshot: snapshot)))

            try await app.testing().test(.POST, "/v1.51/containers/stop-fail-ctr/stop") { res async throws in
                #expect(res.status == .internalServerError)
                let body = try res.content.decode(RouteErrorBody.self)
                #expect(body.reason.contains("Failed to stop container"))
                #expect(body.reason.contains("synthetic VM teardown failure"))
            }
        }
    }
}

@Suite("ContainerDeleteRoute — generic error surfacing")
struct ContainerDeleteRouteGenericErrorTests {

    @Test("A non-ClientContainerError failure surfaces its real reason, not a generic message")
    func genericDeleteFailureSurfacesReason() async throws {
        let snapshot = makeSnapshot(id: "delete-fail-ctr")
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.middleware.use(ErrorMiddleware.default(environment: app.environment))
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerDeleteRoute(client: StopFailureMock(snapshot: snapshot)))

            try await app.testing().test(.DELETE, "/v1.51/containers/delete-fail-ctr") { res async throws in
                #expect(res.status == .internalServerError)
                let body = try res.content.decode(RouteErrorBody.self)
                #expect(body.reason.contains("Failed to delete container"))
                #expect(body.reason.contains("synthetic VM teardown failure"))
            }
        }
    }
}
