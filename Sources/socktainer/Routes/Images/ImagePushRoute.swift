import ContainerAPIClient
import Containerization
import ContainerizationOCI
import Foundation
import Vapor

struct ImagePushRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/{name:.*}/push", use: ImagePushRoute.handler(client: client))
    }
}

struct RESTImagePushQuery: Vapor.Content {
    let tag: String?
    let platform: String?
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

    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
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

            let progressStream: AsyncThrowingStream<String, Error>
            do {
                progressStream = try await client.push(
                    reference: reference,
                    platform: platform,
                    logger: req.logger
                )
            } catch ClientImageError.notFound(let id) {
                throw Abort(.notFound, reason: "No such image: \(id)")
            } catch let abort as Abort {
                throw abort
            } catch {
                throw Abort(.internalServerError, reason: "Failed to push \(reference): \(error)")
            }

            let app = req.application
            // moby's push event uses the familiar reference as Actor.ID and the familiar
            // name without tag as the `name` attribute (daemon/containerd/image_push.go).
            let familiarName = (try? Reference.parse(reference))?.name ?? imageName
            response.body = .init(stream: { writer in
                Task {
                    await DockerProgressFrame.pipe(progressStream, to: writer) {
                        guard let broadcaster = app.storage[EventBroadcasterKey.self] else { return }
                        await broadcaster.broadcast(
                            DockerEvent.make(
                                type: "image", action: "push", actorID: reference,
                                attributes: ["name": familiarName]))
                    }
                }
            })
            return response
        }
    }
}
