import Vapor

struct NetworkPruneRoute: RouteCollection {
    let client: ClientNetworkProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/networks/prune", use: NetworkPruneRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        let networkClient = ClientNetworkService()
        let query = try req.query.decode(RESTNetworksListQuery.self)
        let filtersParam = query.filters

        // Use utility to parse filters (default to dangling)
        let parsedFilters = try DockerNetworkFilterUtility.parseNetworkFilters(filtersParam: filtersParam, defaultDangling: true, logger: req.logger)

        let filtersJSON = try JSONEncoder().encode(parsedFilters)
        let filtersJSONString = String(data: filtersJSON, encoding: .utf8)

        var deletedNetworks: [String] = []
        var errors: [String: String] = [:]
        do {
            let networks = try await networkClient.list(filters: filtersJSONString, logger: req.logger)
            for network in networks {
                if network.Name == "default" {
                    req.logger.info("Skipping deletion of default network: \(network.Id)")
                    continue
                }
                do {
                    // Clean up DNS forwarder sidecar before deleting the network
                    if let dnsManager = req.application.storage[NetworkDNSManagerKey.self] {
                        await dnsManager.cleanupDNSContainer(networkId: network.Id)
                    }
                    try await networkClient.delete(id: network.Id, logger: req.logger)
                    deletedNetworks.append(network.Id)
                } catch {
                    errors[network.Id] = String(describing: error)
                    req.logger.error("Failed to delete network \(network.Id): \(error)")
                }
            }
            let responseBody: [String: Any] = [
                "NetworksDeleted": deletedNetworks,
                "Errors": errors,
            ]
            let responseData = try JSONSerialization.data(withJSONObject: responseBody, options: [])
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                // Docker prune events carry an empty Actor.ID and only a reclaimed attribute;
                // moby always reports reclaimed="0" for networks.
                await broadcaster.broadcast(
                    DockerEvent.make(
                        type: "network", action: "prune", actorID: "",
                        attributes: ["reclaimed": "0"]))
            }
            return Response(status: .ok, body: .init(data: responseData))
        } catch {
            return Response(status: .internalServerError, body: .init(string: "Failed to prune networks: \(error)"))
        }
    }
}
