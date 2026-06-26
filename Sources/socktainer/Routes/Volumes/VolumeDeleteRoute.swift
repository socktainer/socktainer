import Vapor

struct VolumeDeleteRoute: RouteCollection {
    let client: ClientVolumeService

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/volumes/{name}", use: self.handler)
    }

    func handler(_ req: Request) async throws -> Response {
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "Missing volume name")
        }
        do {
            try await client.delete(name: name)
            // Docker Engine API: DELETE /volumes/{name} returns 204 No Content.
            return Response(status: .noContent)
        } catch {
            if let abortError = error as? AbortError {
                throw abortError
            }
            // You may want to check for not found error specifically
            throw Abort(.internalServerError, reason: "Failed to delete volume: \(error)")
        }
    }
}
