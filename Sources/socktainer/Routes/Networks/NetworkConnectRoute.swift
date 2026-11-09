import Vapor

struct RESTNetworkConnect: Content {
    let Container: String
    let EndpointConfig: ContainerEndpointSettings?
}

struct NetworkConnectRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/networks/{id}/connect", use: NetworkConnectRoute.handler(client: client))
    }

    // Apple Container can't attach a network to a running container, so a connect to a
    // network the container isn't on stays a no-op that returns 200, which lets Docker
    // Compose proceed. A connect to a network it is on (after a disconnect, which can't
    // detach it either) applies EndpointConfig.Aliases in socktainer's DNS server.
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let network = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing network ID")
            }
            let body = try req.content.decode(RESTNetworkConnect.self)
            guard let container = try await client.getContainer(id: body.Container) else {
                throw Abort(.notFound, reason: "No such container: \(body.Container)")
            }

            let cidrs = ContainerStartRoute.dnsAttachmentCIDRs(in: container)
            guard container.networks.contains(where: { $0.network == network }),
                let owner = ContainerStartRoute.dnsAttachmentIP(in: container),
                !cidrs.isEmpty
            else {
                return Response(status: .ok)
            }

            let aliases = (body.EndpointConfig?.Aliases ?? []).filter { !$0.isEmpty }
            let previous = ConnectedNetworkAliases.shared.set(nativeId: container.id, network: network, aliases: aliases)
            if let dnsServer = req.application.storage[SocktainerDNSServerKey.self] {
                for name in previous where !aliases.contains(name) {
                    dnsServer.unregisterIfOwned(hostname: name, expectedIP: owner)
                }
                // Registered on every attachment, primary first, as create-time aliases are,
                // so the cleanup paths' ownership check by primary IP matches them.
                for name in aliases {
                    dnsServer.register(hostname: name, ips: cidrs)
                }
            }
            return Response(status: .ok)
        }
    }
}
