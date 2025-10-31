import ContainerClient
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
    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let imageName = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }

            let query = try req.query.decode(RESTImagePushQuery.self)

            // Extract and decode X-Registry-Auth header
            var registryAuth: AuthConfig?
            if let xAuthConfigHeader = req.headers.first(name: "X-Registry-Auth") {
                if let decodedData = Data(base64Encoded: xAuthConfigHeader),
                    let auth = try? JSONDecoder().decode(AuthConfig.self, from: decodedData)
                {
                    registryAuth = auth
                }
            }

            // Build the full reference (name:tag)
            let reference: String
            if let tag = query.tag, !tag.isEmpty {
                reference = "\(imageName):\(tag)"
            } else {
                // If no tag is provided, push all tags (use the name as-is)
                reference = imageName
            }

            // Parse platform if provided
            let platform: Platform?
            if let platformString = query.platform, !platformString.isEmpty {
                do {
                    platform = try platformOrThrow(platformString)
                } catch {
                    let response = Response(status: .internalServerError)
                    response.headers.add(name: .contentType, value: "application/json")
                    response.body = .init(string: "{\"message\": \"Failed to parse platform\"}\n")
                    return response
                }
            } else {
                platform = nil
            }

            let response = Response()
            response.headers.add(name: .contentType, value: "application/json")

            let progressStream = try await client.push(
                reference: reference,
                platform: platform,
                registryAuth: registryAuth,
                logger: req.logger
            )

            response.body = .init(stream: { writer in
                Task {
                    do {
                        for try await progress in progressStream {
                            let json = "{\"status\": \"\(progress.replacingOccurrences(of: "\"", with: "\\\""))\"}"
                            _ = writer.write(.buffer(ByteBuffer(string: json + "\n")))
                        }
                        _ = writer.write(.end)
                    } catch {
                        _ = writer.write(.buffer(ByteBuffer(string: "{\"error\": \"\(error.localizedDescription)\"}\n")))
                        _ = writer.write(.error(error))
                    }
                }
            })
            return response
        }
    }
}
