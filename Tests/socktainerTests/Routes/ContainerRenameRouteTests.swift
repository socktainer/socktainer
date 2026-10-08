import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private actor RenameMock: ClientContainerProtocol {
    let failure: ClientContainerError?
    private(set) var calls: [(id: String, newName: String)] = []

    init(failure: ClientContainerError? = nil) { self.failure = failure }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func rename(id: String, newName: String) async throws {
        calls.append((id, newName))
        if let failure { throw failure }
    }
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

private func withRenameApp(_ mock: RenameMock, _ body: (Application) async throws -> Void) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
        try app.register(collection: ContainerRenameRoute(client: mock))
        try await body(app)
    }
}

@Suite("ContainerRenameRoute")
struct ContainerRenameRouteTests {
    @Test("Renames to the requested name, accepting a leading slash")
    func renames() async throws {
        let mock = RenameMock()
        try await withRenameApp(mock) { app in
            try await app.testing().test(.POST, "/v1.51/containers/abc_web-1/rename?name=/web-1") { res async in
                #expect(res.status == .noContent)
            }
        }
        let calls = await mock.calls
        #expect(calls.count == 1)
        #expect(calls.first?.id == "abc_web-1")
        #expect(calls.first?.newName == "web-1")
    }

    @Test("A missing name is a bad request")
    func missingName() async throws {
        let mock = RenameMock()
        try await withRenameApp(mock) { app in
            try await app.testing().test(.POST, "/v1.51/containers/web-1/rename") { res async in
                #expect(res.status == .badRequest)
            }
        }
        #expect(await mock.calls.isEmpty)
    }

    @Test(
        "Client errors map to Docker status codes",
        arguments: [
            (ClientContainerError.notFound(id: "web-1"), HTTPStatus.notFound),
            (ClientContainerError.nameConflict("db-1"), HTTPStatus.conflict),
            (ClientContainerError.renameRequiresUnstarted(id: "web-1"), HTTPStatus.conflict),
            (ClientContainerError.invalidName("bad name"), HTTPStatus.badRequest),
        ])
    func mapsErrors(failure: ClientContainerError, status: HTTPStatus) async throws {
        try await withRenameApp(RenameMock(failure: failure)) { app in
            try await app.testing().test(.POST, "/v1.51/containers/web-1/rename?name=db-1") { res async in
                #expect(res.status == status)
            }
        }
    }
}
