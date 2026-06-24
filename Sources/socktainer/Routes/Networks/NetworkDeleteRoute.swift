import ContainerAPIClient
import Vapor

struct NetworkDeleteRoute: RouteCollection {
    let client: ClientNetworkProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/networks/{id}", use: self.handler)
    }

    func handler(_ req: Request) async throws -> Response {
        let logger = req.logger
        guard let id = req.parameters.get("id") else {
            logger.warning("Missing network id parameter")
            throw Abort(.badRequest, reason: "Missing network id parameter")
        }
        do {
            // Resolve the network before deletion: getNetwork returns the canonical Id,
            // Name and Driver, so a request by name/short-id maps to the real network for
            // DNS cleanup and the destroy event (moby network events include {name, type}).
            let summary = try? await client.getNetwork(id: id, logger: logger)
            let resolvedId = summary?.Id ?? id

            // Remove the CoreDNS sidecar BEFORE deleting the network —
            // the network can't be deleted while the DNS container is still attached.
            if let dnsManager = req.application.storage[NetworkDNSManagerKey.self] {
                await dnsManager.cleanupDNSContainer(networkId: resolvedId)
            }
            try await client.delete(id: resolvedId, logger: logger)
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                await broadcaster.broadcast(
                    DockerEvent.make(
                        type: "network", action: "destroy", actorID: resolvedId,
                        attributes: ["name": summary?.Name ?? id, "type": summary?.Driver ?? "nat"]))
            }
            return Response(status: .noContent)
        } catch {
            if error.localizedDescription.contains("not found") {
                throw Abort(.notFound, reason: "Network not found")
            }
            throw Abort(.internalServerError, reason: "Network deletion failed: \(error)")
        }
    }
}
