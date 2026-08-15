import Logging
import Testing
import Vapor
import VaporTesting

@testable import GlassDock

@Suite("VolumeCreateRoute — reserved sync metadata")
struct VolumeCreateReservedLabelTests {
    @Test(
        "callers cannot inject Glass Dock's internal sync label",
        arguments: ["glassdock.volume.sync", "GLASSDOCK.VOLUME.SYNC"])
    func rejectsInternalSyncLabel(label: String) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: VolumeCreateRoute(client: UnusedVolumeClient()))

            try await app.testing().test(
                .POST,
                "/v1.51/volumes/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"qa","Labels":{"\#(label)":"nosync"}}"#)
            ) { response async in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("reserved for internal use"))
            }
        }
    }
}

private struct UnusedVolumeClient: ClientVolumeProtocol {
    func create(request: RESTVolumeCreate) async throws -> Volume { fatalError("must reject before create") }
    func delete(name: String) async throws { fatalError("unused") }
    func list(filters: String?, logger: Logger) async throws -> [Volume] { fatalError("unused") }
    func inspect(name: String) async throws -> Volume { fatalError("unused") }
}
