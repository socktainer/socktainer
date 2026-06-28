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
        // Capture the driver before deletion so the destroy event can report it
        // (moby volume events include {driver}).
        let driver = (try? await client.inspect(name: name))?.Driver ?? "local"
        do {
            try await client.delete(name: name)
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                await broadcaster.broadcast(
                    DockerEvent.make(
                        type: "volume", action: "destroy", actorID: name,
                        attributes: ["driver": driver]))
            }
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
