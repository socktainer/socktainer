import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Docker's volume create returns an existing volume of the same name; podman's fails unless
/// `IgnoreIfExists` is set. podman can also ask for an owner the backend cannot apply.
@Suite("LibpodVolumeCreateRoute — podman create semantics")
struct LibpodVolumeCreateRouteTests {
    private func withVolumeApp(exists: Bool, _ body: (Application) async throws -> Void) async throws {
        try await withApp(configure: { app in app.middleware.use(DockerErrorMiddleware()) }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(
                collection: LibpodVolumeCreateRoute(dockerRoute: VolumeCreateRoute(client: ClientVolumeService()), volumeExists: { _ in exists }))
            try await body(app)
        }
    }

    @Test("creating a volume that already exists is a conflict without IgnoreIfExists")
    func existingVolumeConflicts() async throws {
        try await withVolumeApp(exists: true) { app in
            try await app.testing().test(
                .POST, "/v1.51/libpod/volumes/create", beforeRequest: { req in req.body = ByteBuffer(string: #"{"Name":"data"}"#) }
            ) { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("volume with name data already exists"))
            }
        }
    }

    @Test("an ownership request is refused instead of silently dropped")
    func ownershipIsRefused() async throws {
        try await withVolumeApp(exists: false) { app in
            for body in [#"{"Name":"data","UID":1000}"#, #"{"Name":"data","GID":1000}"#] {
                try await app.testing().test(
                    .POST, "/v1.51/libpod/volumes/create", beforeRequest: { req in req.body = ByteBuffer(string: body) }
                ) { res async in
                    #expect(res.status == .badRequest)
                }
            }
        }
    }
}
