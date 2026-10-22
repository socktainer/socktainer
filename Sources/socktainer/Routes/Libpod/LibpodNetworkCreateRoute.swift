import Foundation
import Vapor

struct LibpodNetworkCreateRoute: RouteCollection {
    let dockerRoute: NetworkCreateRoute

    func boot(routes: RoutesBuilder) throws {
        // Podman posts its own `types.Network` (lower-case keys, no Content-Type) and expects that
        // network back; Docker-compat wants `NetworksCreateQuery` and answers `{Id, Warning}`.
        let handler = LibpodAdapter.reshaping(
            dockerRoute.handler,
            prepare: { req in
                let body = try await LibpodAdapter.jsonObjectBody(of: req)
                req.storage[LibpodRequestBodyKey.self] = try JSONSerialization.data(withJSONObject: body)
                return try LibpodAdapter.replacingBody(of: req, with: LibpodSchema.dockerNetworkCreateBody(fromLibpod: body))
            }
        ) { _, req in
            let original = req.storage[LibpodRequestBodyKey.self].flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return LibpodSchema.networkCreated(fromLibpod: original ?? [:])
        }
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/networks/create", use: handler)
    }
}

/// The original libpod request body, kept so the response can be built from it.
struct LibpodRequestBodyKey: StorageKey {
    typealias Value = Data
}
