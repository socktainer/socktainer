import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// podman decides whether to log a removal error by looking for its own lower-case text
/// (`no such container`) inside the message, and parses `cause`/`message`/`response` from error bodies.
@Suite("DockerErrorMiddleware — libpod errors")
struct DockerErrorMiddlewareLibpodTests {
    private static func json(_ response: Response) throws -> [String: Any] {
        let buffer = try #require(response.body.buffer)
        let object = try JSONSerialization.jsonObject(with: Data(buffer: buffer))
        return try #require(object as? [String: Any])
    }

    @Test("libpod messages lower-case a leading 'No such'; other messages are unchanged")
    func libpodMessage() {
        #expect(DockerErrorMiddleware.libpodMessage("No such container: abc") == "no such container: abc")
        #expect(DockerErrorMiddleware.libpodMessage("No such image: x:1") == "no such image: x:1")
        #expect(DockerErrorMiddleware.libpodMessage("Missing container ID") == "Missing container ID")
    }

    @Test("only the route prefix marks a libpod request, not a `libpod` segment in an image name")
    func libpodPathPrefix() {
        #expect(DockerErrorMiddleware.isLibpodPath("/libpod/containers/json"))
        #expect(DockerErrorMiddleware.isLibpodPath("/v5.0.0/libpod/containers/json"))
        #expect(DockerErrorMiddleware.isLibpodPath("/v1.51/libpod/info"))
        #expect(!DockerErrorMiddleware.isLibpodPath("/v1.51/images/quay.io/libpod/alpine:latest/json"))
        #expect(!DockerErrorMiddleware.isLibpodPath("/images/quay.io/libpod/alpine/json"))
        #expect(!DockerErrorMiddleware.isLibpodPath("/volumes/libpod"))
        #expect(!DockerErrorMiddleware.isLibpodPath("/v1.51/volumes/libpod"))
    }

    @Test("libpod error bodies carry podman's cause and response next to the Docker fields")
    func libpodErrorBody() throws {
        let response = DockerErrorMiddleware.makeDockerError(status: .notFound, message: "no such container: x", libpod: true)
        let body = try Self.json(response)
        #expect(body["message"] as? String == "no such container: x")
        #expect(body["cause"] as? String == "no such container: x")
        #expect(body["response"] as? Int == 404)

        let docker = DockerErrorMiddleware.makeDockerError(status: .notFound, message: "No such container: x")
        let dockerBody = try Self.json(docker)
        #expect(dockerBody["cause"] == nil && dockerBody["response"] == nil)
    }

    @Test("a missing container is `no such container` on the libpod route and unchanged on the Docker one")
    func missingContainerOverHTTP() async throws {
        try await withApp(configure: { app in app.middleware.use(DockerErrorMiddleware(), at: .beginning) }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodContainerDeleteRoute(client: MissingContainerClient()))
            try app.register(collection: ContainerDeleteRoute(client: MissingContainerClient()))

            try await app.testing().test(.DELETE, "/v1.51/libpod/containers/gone") { res async throws in
                #expect(res.status == .notFound)
                let body = try #require(try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])
                #expect((body["message"] as? String)?.hasPrefix("no such container") == true)
                #expect(body["response"] as? Int == 404)
            }
            try await app.testing().test(.DELETE, "/v1.51/containers/gone") { res async throws in
                #expect(res.status == .notFound)
                let body = try #require(try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])
                #expect((body["message"] as? String)?.hasPrefix("No such container") == true)
            }
        }
    }
}

private struct MissingContainerClient: ClientContainerProtocol {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws { throw ClientContainerError.notFound(id: id) }
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait { RESTContainerWait(statusCode: 0) }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
}
