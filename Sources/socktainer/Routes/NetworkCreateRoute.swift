import Vapor

struct NetworksCreateQuery: Content {
    let Name: String
    // NOTE: All fields are optional and are not supported or used
    //       by Apple container. This should be revisited in the future.
    let Driver: String?
    let scope: String?
    let Internal: Bool?
    let Attachable: Bool?
    let ingress: Bool?
    let ConfigOnly: Bool?
    let ConfigFrom: NetworkConfigReference?
    let IPAM: NetworkIPAM?
    let EnableIPv4: Bool?
    let EnableIPv6: Bool?
    let Options: [String: String]?
    let Labels: [String: String]?
}

struct NetworkCreateRoute: RouteCollection {
    let client: ClientNetworkProtocol
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "networks", "create", use: self.handler)
    }

    func handler(_ req: Request) async throws -> Response {
        let logger = req.logger
        let query = try req.content.decode(NetworksCreateQuery.self)
        // only pass network name
        let response = try await client.create(name: query.Name, logger: logger)
        return try await response.encodeResponse(for: req)
    }
}
