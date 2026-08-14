import Vapor

struct VolumeDeleteRoute: RouteCollection {
    let client: ClientVolumeProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/volumes/{name}", use: self.handler)
    }

    func handler(_ req: Request) async throws -> Response {
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "Missing volume name")
        }
        // Docker Engine API: `force` removes the volume even if it does not exist.
        let force = MobyBool.queryValue(req.query["force"] as String?)

        // moby inspects the volume before removing it: to look up its driver for
        // the destroy event, and to tell "missing" apart from a real failure.
        // Without force a missing volume is a 404; with force it is a silent 204.
        let volume: Volume
        do {
            volume = try await client.inspect(name: name)
        } catch {
            if VolumeNotFound.matches(error) {
                // force purges a missing volume silently (204); otherwise 404.
                if force {
                    return Response(status: .noContent)
                }
                throw Abort(.notFound, reason: "get \(name): no such volume")
            }
            throw Abort(.internalServerError, reason: "Failed to inspect volume: \(error)")
        }

        do {
            if let runtime = client as? RuntimeVolumeService {
                try await runtime.deleteIfUnused(name: name)
            } else {
                try await client.delete(name: name)
            }
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                await broadcaster.broadcast(
                    DockerEvent.make(
                        type: "volume", action: "destroy", actorID: name,
                        attributes: ["driver": volume.Driver]))
            }
            // Docker Engine API: DELETE /volumes/{name} returns 204 No Content.
            return Response(status: .noContent)
        } catch {
            if let abortError = error as? AbortError {
                throw abortError
            }
            // The volume can vanish between the inspect above and this delete
            // (another client, or `container volume rm`). moby maps that race to
            // the same force contract: a silent 204 under force, else a 404.
            if VolumeNotFound.matches(error) {
                if force {
                    return Response(status: .noContent)
                }
                throw Abort(.notFound, reason: "get \(name): no such volume")
            }
            throw Abort(.internalServerError, reason: "Failed to delete volume: \(error)")
        }
    }
}
