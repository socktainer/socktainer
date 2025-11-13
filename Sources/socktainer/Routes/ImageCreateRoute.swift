import Foundation
import Vapor

struct ImageCreateRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/create", use: ImageCreateRoute.handler(client: client))
    }
}

struct RESTImageCreateQuery: Content {
    let fromImage: String?
    let tag: String?
    let platform: String?
    // TODO: Revisit it later
    // let fromSrc: String?
    // let repo: String?
    // let message: String?
    // let inputImage: String?
    // let changes: [String]?
}

extension ImageCreateRoute {
    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let query = try req.query.decode(RESTImageCreateQuery.self)
            let image = ContainerImageUtility.normalizeImageReference(query.fromImage ?? "")
            let tag = query.tag ?? ""
            let decodedTag = tag.removingPercentEncoding ?? tag
            let platformString = query.platform
            let platform: Platform
            if let platformString, !platformString.isEmpty {
                do {
                    platform = try platformOrThrow(platformString)
                } catch {
                    let response = Response(status: .internalServerError)
                    response.headers.add(name: .contentType, value: "application/json")
                    response.body = .init(string: "{\"message\": \"Failed to parse platform\"}\n")
                    return response
                }
            } else {
                platform = currentPlatform()
            }

            // Extract and decode X-Registry-Auth header
            var registryAuth: AuthConfig?
            if let xAuthConfigHeader = req.headers.first(name: "X-Registry-Auth") {
                if let decodedData = Data(base64Encoded: xAuthConfigHeader),
                    let auth = try? JSONDecoder().decode(AuthConfig.self, from: decodedData)
                {
                    registryAuth = auth
                }
            }

            guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                throw Abort(.internalServerError, reason: "AppleContainerAppSupportUrl not configured")
            }

            let response = Response()
            response.headers.add(name: .contentType, value: "application/json")
            let progressStream = try await client.pull(
                image: image, tag: decodedTag, platform: platform, registryAuth: registryAuth, appleContainerAppSupportUrl: appleContainerAppSupportUrl, logger: req.logger)

            response.body = .init(stream: { writer in
                Task {
                    do {
                        for try await progress in progressStream {
                            let json = "{\"status\": \"\(progress.replacingOccurrences(of: "\"", with: "\\\""))\"}"  // Docker style
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
