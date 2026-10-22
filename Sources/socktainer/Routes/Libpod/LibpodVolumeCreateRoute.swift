import Vapor

struct LibpodVolumeCreateRoute: RouteCollection {
    let dockerRoute: VolumeCreateRoute

    func boot(routes: RoutesBuilder) throws {
        // Podman's `VolumeCreateOptions` uses `Label`/`Options` and arrives without a Content-Type.
        let handler = LibpodAdapter.reshaping(
            dockerRoute.handler, status: .created,
            prepare: { req in
                let body = try await LibpodAdapter.jsonObjectBody(of: req)
                return try LibpodAdapter.replacingBody(of: req, with: LibpodSchema.dockerVolumeCreateBody(fromLibpod: body))
            }
        ) { body, _ in LibpodSchema.volumeObject(body) }
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/volumes/create", use: handler)
    }
}
