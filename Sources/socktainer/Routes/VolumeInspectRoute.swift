import Vapor

struct VolumeInspectRoute: RouteCollection {
    let client: ClientVolumeService

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/volumes/{name}", use: self.handler)
    }

    func handler(_ req: Request) async throws -> Response {
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "Missing volume name parameter")
        }
        do {
            let volume = try await client.inspect(name: name)
            return try await volume.encodeResponse(for: req)
        } catch {
            // Generic error handling: if error indicates not found, return 404
            let errorDescription = String(describing: error)
            if errorDescription.contains("not found") || errorDescription.contains("No such volume") {
                throw Abort(.notFound, reason: "Volume not found: \(name)")
            }
            throw Abort(.internalServerError, reason: "Failed to inspect volume: \(error)")
        }
    }
}
