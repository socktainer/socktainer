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
        try routes.registerVersionedRoute(.POST, pattern: "/networks/create", use: self.handler)
    }

    func handler(_ req: Request) async throws -> Response {
        let logger = req.logger
        let query = try req.content.decode(NetworksCreateQuery.self)
        // only pass network name and labels for now
        let originalLabels = query.Labels ?? [:]
        guard !LabelNormalization.containsReservedKey(originalLabels) else {
            throw Abort(.badRequest, reason: "Label key '\(LabelNormalization.mappingKey)' is reserved for internal use")
        }
        var labels = LabelNormalization.sanitize(originalLabels)
        if let mapping = LabelNormalization.buildMapping(originalLabels) {
            labels[LabelNormalization.mappingKey] = mapping
        }
        let response: RESTNetworkCreate
        do {
            response = try await client.create(name: query.Name, labels: labels, logger: logger)
            // moby network events carry {name, type} where type is the driver.
            // Only broadcast on actual creation — not on the idempotent "already exists" path.
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                await broadcaster.broadcast(
                    DockerEvent.make(
                        type: "network", action: "create", actorID: response.Id,
                        attributes: ["name": query.Name, "type": "nat"]))
            }
        } catch {
            // Docker's `network create` is effectively create-to-ensure for tools
            // (e.g. the Supabase CLI) that may issue it more than once during a
            // single bring-up; socktainer's create throws "already exists", which
            // those tools treat as a fatal "failed to create docker network".
            // Only treat that specific conflict as idempotent — return the
            // existing network; any other failure is a real error and propagates.
            // (Mirrors VolumeCreateRoute's idempotent create.)
            guard "\(error)".lowercased().contains("already exists") else { throw error }
            guard let existing = try await client.getNetwork(id: query.Name, logger: logger) else { throw error }
            response = RESTNetworkCreate(Id: existing.Id, Warning: "")
        }
        // Docker Engine API: POST /networks/create returns 201 Created.
        let httpResponse = try await response.encodeResponse(for: req)
        httpResponse.status = .created
        return httpResponse
    }
}
