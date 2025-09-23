import Vapor

struct NetworkPruneRoute: RouteCollection {
    let client: ClientNetworkProtocol
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "networks", "prune", use: NetworkPruneRoute.handler)
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
            return Response(status: .ok, body: .init(data: responseData))
        } catch {
            return Response(status: .internalServerError, body: .init(string: "Failed to prune networks: \(error)"))
        }
    }
}
