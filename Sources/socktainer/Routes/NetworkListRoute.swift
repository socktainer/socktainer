import Vapor

struct RESTNetworksListQuery: Content {
    let filters: String?
}

struct NetworkListRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "networks", use: NetworkListRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        let networkClient = ClientNetworkService()
        let query = try req.query.decode(RESTNetworksListQuery.self)
        let filtersParam = query.filters

        let parsedFilters = try DockerNetworkFilterUtility.parseNetworkFilters(filtersParam: filtersParam, defaultDangling: false, logger: req.logger)

        let filtersJSON = try JSONEncoder().encode(parsedFilters)
        let filtersJSONString = String(data: filtersJSON, encoding: .utf8)

        do {
            let networks = try await networkClient.list(filters: filtersJSONString, logger: req.logger)
            return Response(status: .ok, body: .init(data: try JSONEncoder().encode(networks)))
        } catch {
            return Response(status: .internalServerError, body: .init(string: "Failed to list networks: \(error)"))
        }
    }
}
