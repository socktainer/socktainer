import Vapor

struct RESTManifestPushQuery: Content {
    let destination: String?
}

struct LibpodManifestPushRoute: RouteCollection {
    let manifestClient: ClientManifestServiceProtocol
    let imageClient: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .POST, pattern: "/libpod/manifests/{name:.*}/registry/{destination:.*}",
            use: LibpodManifestPushRoute.pathDestinationHandler(manifestClient: manifestClient, imageClient: imageClient))
        // Legacy (pre-4.0) form: destination as a query param instead of a path segment.
        try routes.registerVersionedRoute(
            .POST, pattern: "/libpod/manifests/{name:.*}/push",
            use: LibpodManifestPushRoute.queryDestinationHandler(manifestClient: manifestClient, imageClient: imageClient))
    }

    static func pathDestinationHandler(manifestClient: ClientManifestServiceProtocol, imageClient: ClientImageProtocol)
        -> @Sendable (Request) async throws
        -> Response
    {
        { req in
            guard let destination = req.parameters.get("destination"), !destination.isEmpty else {
                throw Abort(.badRequest, reason: "Missing push destination")
            }
            return try await push(req, manifestClient: manifestClient, imageClient: imageClient, destination: destination)
        }
    }

    static func queryDestinationHandler(manifestClient: ClientManifestServiceProtocol, imageClient: ClientImageProtocol)
        -> @Sendable (Request) async throws
        -> Response
    {
        { req in
            let query = try req.query.decode(RESTManifestPushQuery.self)
            guard let destination = query.destination, !destination.isEmpty else {
                throw Abort(.badRequest, reason: "destination is required")
            }
            return try await push(req, manifestClient: manifestClient, imageClient: imageClient, destination: destination)
        }
    }

    private static func push(
        _ req: Request, manifestClient: ClientManifestServiceProtocol, imageClient: ClientImageProtocol, destination: String
    ) async throws -> Response {
        guard let name = req.parameters.get("name"), !name.isEmpty else {
            throw Abort(.badRequest, reason: "Missing manifest list name")
        }

        let response = Response()
        response.headers.add(name: .contentType, value: "application/json")

        // Re-tag under `destination` first — push always pushes to the same reference it
        // resolves from, so a differing destination needs the local index re-pointed there
        // before the network push runs. `retagState` is nil when destination == name (no-op);
        // otherwise it captures destination's prior state (what it pointed at before, or that it
        // didn't exist) so it can be restored once the push finishes — success or failure —
        // rather than either leaking a stray tag or clobbering a pre-existing one permanently.
        let finalReference: String
        let finalRetagState: RetagState?
        do {
            (finalReference, finalRetagState) = try await manifestClient.retagForPush(name: name, destination: destination)
        } catch ClientImageError.notFound(let id) {
            throw Abort(.notFound, reason: "No such manifest list: \(id)")
        } catch is ClientManifestError {
            throw Abort(.notFound, reason: "No such manifest list: \(name)")
        }

        let progressStream: AsyncThrowingStream<String, Error>
        do {
            progressStream = try await imageClient.pushManifestList(reference: finalReference, logger: req.logger)
        } catch {
            if let finalRetagState {
                do {
                    try await manifestClient.untagPushDestination(finalRetagState)
                } catch {
                    req.logger.warning("Failed to restore \(finalRetagState.reference)'s prior state after a failed push: \(error)")
                }
            }
            if case ClientImageError.notFound(let id) = error {
                throw Abort(.notFound, reason: "No such manifest list: \(id)")
            }
            throw Abort(.internalServerError, reason: "Failed to push manifest list \(name): \(error)")
        }

        let logger = req.logger
        response.body = .init(stream: { writer in
            Task {
                await DockerProgressFrame.pipe(
                    progressStream, to: writer, useStreamKey: true,
                    finalFrame: {
                        do {
                            return DockerProgressFrame.manifestPushId(try await manifestClient.digest(for: finalReference))
                        } catch {
                            logger.warning("Manifest push of \(finalReference) succeeded but digest lookup for the completion frame failed: \(error)")
                            return nil
                        }
                    })
                if let finalRetagState {
                    // A fresh, unstructured `Task` here (not just the tail of the enclosing
                    // one) so this cleanup still runs even if the response stream's own Task
                    // was cancelled (e.g. the client disconnected mid-push) — `Task { ... }`
                    // does NOT inherit the creating task's cancellation state, unlike a
                    // structured child task.
                    Task {
                        do {
                            try await manifestClient.untagPushDestination(finalRetagState)
                        } catch {
                            logger.warning("Failed to restore \(finalRetagState.reference)'s prior state after push: \(error)")
                        }
                    }
                }
            }
        })
        return response
    }
}
