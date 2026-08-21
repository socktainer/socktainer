import ContainerAPIClient
import Containerization
import ContainerizationOCI
import Foundation
import Vapor

struct ImagePushRoute: RouteCollection {
    let client: ClientImageProtocol
    let manifestClient: ClientManifestServiceProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .POST, pattern: "/images/{name:.*}/push", use: ImagePushRoute.handler(client: client, manifestClient: manifestClient, useStreamKey: false))
    }
}

struct RESTImagePushQuery: Vapor.Content {
    let tag: String?
    let platform: String?
    let destination: String?
}

extension ImagePushRoute {
    private static func resolvedReference(imageName: String, tag: String?) throws -> String {
        guard let tag, !tag.isEmpty else {
            return imageName
        }

        let parsedReference = try Reference.parse(imageName)
        if tag.starts(with: "sha256:") {
            return try parsedReference.withDigest(tag).description
        }
        return try parsedReference.withTag(tag).description
    }

    static func handler(client: ClientImageProtocol, manifestClient: ClientManifestServiceProtocol, useStreamKey: Bool) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let imageName = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }

            let query = try req.query.decode(RESTImagePushQuery.self)

            let reference = try resolvedReference(imageName: imageName, tag: query.tag)

            // Parse platform if provided
            let platform: Platform?
            if let platformString = query.platform, !platformString.isEmpty {
                do {
                    platform = try platformOrThrow(platformString)
                } catch {
                    throw Abort(.badRequest, reason: "invalid platform: \(platformString)")
                }
            } else {
                platform = nil
            }

            let response = Response()
            response.headers.add(name: .contentType, value: "application/json")

            // Real podman (`pkg/bindings/images`'s `Push`) sends the push destination as a
            // separate `destination` query param — the path reference is always the LOCAL
            // source image, never the target registry. Without honoring it, push targets
            // whatever (if anything) the source reference's own domain resolves to, silently
            // ignoring where the caller actually asked to push. Mirrors manifest push's own
            // retag-then-push-then-restore dance (`ClientManifestService.retagForPush`/
            // `untagPushDestination`) since the underlying push primitive always pushes to
            // the same reference it resolves from.
            var pushReference = reference
            var retagState: RetagState?
            if let destination = query.destination, !destination.isEmpty {
                do {
                    (pushReference, retagState) = try await manifestClient.retagForPush(name: reference, destination: destination)
                } catch ClientImageError.notFound(let id) {
                    throw Abort(.notFound, reason: "No such image: \(id)")
                } catch is ClientManifestError {
                    throw Abort(.notFound, reason: "No such image: \(reference)")
                }
            }
            let finalReference = pushReference
            let finalRetagState = retagState

            @Sendable func restoreRetagStateIfNeeded() async {
                guard let finalRetagState else { return }
                do {
                    try await manifestClient.untagPushDestination(finalRetagState)
                } catch {
                    req.logger.warning("Failed to restore \(finalRetagState.reference)'s prior state after a failed push: \(error)")
                }
            }

            let progressStream: AsyncThrowingStream<String, Error>
            do {
                progressStream = try await client.push(
                    reference: finalReference,
                    platform: platform,
                    logger: req.logger
                )
            } catch ClientImageError.notFound(let id) {
                await restoreRetagStateIfNeeded()
                throw Abort(.notFound, reason: "No such image: \(id)")
            } catch let abort as Abort {
                await restoreRetagStateIfNeeded()
                throw abort
            } catch {
                await restoreRetagStateIfNeeded()
                throw Abort(.internalServerError, reason: "Failed to push \(finalReference): \(error)")
            }

            let app = req.application
            let logger = req.logger
            // moby's push event uses the familiar reference as Actor.ID and the familiar
            // name without tag as the `name` attribute (daemon/containerd/image_push.go).
            let familiarName = (try? Reference.parse(finalReference))?.name ?? imageName
            // Real podman clients (`pkg/bindings/images`'s `Push`) decode each line into a
            // struct with a `stream` field, not `status` — this route is shared between the
            // Docker-compat path (`/images/{name}/push`, `useStreamKey: false`) and the libpod
            // one (`/libpod/images/{name}/push`, see `LibpodImagePushRoute`, `useStreamKey: true`),
            // which do need different framing. Passed explicitly by each route's own
            // registration rather than derived from the request path, so it can't silently
            // pick the wrong framing for an image name that happens to contain "/libpod/".
            response.body = .init(stream: { writer in
                Task {
                    await DockerProgressFrame.pipe(
                        progressStream, to: writer, useStreamKey: useStreamKey,
                        onSuccess: {
                            guard let broadcaster = app.storage[EventBroadcasterKey.self] else { return }
                            await broadcaster.broadcast(
                                DockerEvent.make(
                                    type: "image", action: "push", actorID: finalReference,
                                    attributes: ["name": familiarName]))
                        })
                    if let finalRetagState {
                        // A fresh, unstructured `Task` here (not just the tail of the
                        // enclosing one) so this cleanup still runs even if the response
                        // stream's own Task was cancelled (e.g. the client disconnected
                        // mid-push) — `Task { ... }` does NOT inherit the creating task's
                        // cancellation state, unlike a structured child task.
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
}
