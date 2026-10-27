import Vapor

struct LibpodVolumeCreateRoute: RouteCollection {
    let dockerRoute: VolumeCreateRoute
    /// Whether a volume of that name exists; defaults to asking the volume backend.
    var volumeExists: (@Sendable (String) async -> Bool)? = nil

    func boot(routes: RoutesBuilder) throws {
        let volumeExists = self.volumeExists ?? { [client = dockerRoute.client] name in (try? await client.inspect(name: name)) != nil }
        // Podman's `VolumeCreateOptions` uses `Label`/`Options` and arrives without a Content-Type.
        let handler = LibpodAdapter.reshaping(
            dockerRoute.handler, status: .created,
            prepare: { req in
                let body = try await LibpodAdapter.jsonObjectBody(of: req)
                // Volumes here are created root-owned; refuse an ownership request rather than
                // report success with it silently dropped.
                for key in ["UID", "GID"] where body[key] != nil && !(body[key] is NSNull) {
                    throw Abort(.badRequest, reason: "setting a volume's owner (\(key)) is not supported")
                }
                // Docker's create returns an existing volume of the same name; podman's fails
                // unless `IgnoreIfExists` (`--ignore`) is set.
                if let name = body["Name"] as? String, !name.isEmpty, !((body["IgnoreIfExists"] as? Bool) ?? false), await volumeExists(name) {
                    throw Abort(.conflict, reason: "volume with name \(name) already exists: volume already exists")
                }
                return try LibpodAdapter.replacingBody(of: req, with: LibpodSchema.dockerVolumeCreateBody(fromLibpod: body))
            }
        ) { body, _ in LibpodSchema.volumeObject(body) }
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/volumes/create", use: handler)
    }
}
