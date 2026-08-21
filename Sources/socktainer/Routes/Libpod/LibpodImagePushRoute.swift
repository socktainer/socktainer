import Vapor

struct LibpodImagePushRoute: RouteCollection {
    let client: ClientImageProtocol
    let manifestClient: ClientManifestServiceProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .POST, pattern: "/libpod/images/{name:.*}/push", use: ImagePushRoute.handler(client: client, manifestClient: manifestClient, useStreamKey: true))
    }
}
