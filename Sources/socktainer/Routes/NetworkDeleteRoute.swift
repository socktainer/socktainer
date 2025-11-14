import Vapor

struct NetworkDeletetRoute: RouteCollection {
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
            try await client.delete(id: id, logger: logger)
            return Response(status: .noContent)
        } catch {
            if error.localizedDescription.contains("not found") {
                throw Abort(.notFound, reason: "Network not found")
            }
            throw Abort(.internalServerError, reason: "Network deletion failed: \(error)")
        }
    }
}
