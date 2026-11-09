import Vapor

struct RESTNetworkDisconnect: Content {
    let Container: String
    let Force: Bool?
}

struct NetworkDisconnectRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/networks/{id}/disconnect", use: NetworkDisconnectRoute.handler(client: client))
    }

    // Apple Container can't detach a network either, so this only drops the aliases an
    // earlier connect added on this network.
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let network = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing network ID")
            }
            let body = try req.content.decode(RESTNetworkDisconnect.self)
            guard let container = try await client.getContainer(id: body.Container) else {
                if body.Force == true { return Response(status: .ok) }
                throw Abort(.notFound, reason: "No such container: \(body.Container)")
            }

            let removed = ConnectedNetworkAliases.shared.set(nativeId: container.id, network: network, aliases: [])
            if let dnsServer = req.application.storage[SocktainerDNSServerKey.self],
                let owner = ContainerStartRoute.dnsAttachmentIP(in: container)
            {
                for name in removed {
                    dnsServer.unregisterIfOwned(hostname: name, expectedIP: owner)
                }
            }
            return Response(status: .ok)
        }
    }
}
