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
        ) { [client = dockerRoute.client] _, req in
            let original = req.storage[LibpodRequestBodyKey.self].flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            var created = LibpodSchema.networkCreated(fromLibpod: original)
            // The backend allocates a subnet when the request names none; report the one it chose.
            if let name = original["name"] as? String,
                let network = try await client.getNetwork(id: name, logger: req.logger),
                let summary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(network)) as? [String: Any],
                let subnets = LibpodSchema.network(summary)["subnets"] as? [[String: Any]], !subnets.isEmpty
            {
                created["subnets"] = subnets
            }
            return created
        }
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/networks/create", use: handler)
    }
}

/// The original libpod request body, kept so the response can be built from it.
struct LibpodRequestBodyKey: StorageKey {
    typealias Value = Data
}
