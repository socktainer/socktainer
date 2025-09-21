import Foundation
import Vapor

struct ImageCreateRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "images", "create", use: ImageCreateRoute.handler(client: client))
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
    // let xRegistryAuth: String?
    // let changes: [String]?
}

extension ImageCreateRoute {
    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let query = try req.query.decode(RESTImageCreateQuery.self)
            let image = query.fromImage ?? ""
            let tag = query.tag ?? ""
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
            let response = Response()
            response.headers.add(name: .contentType, value: "application/json")
            let progressStream = try await client.pull(image: image, tag: tag, platform: platform, logger: req.logger)

            response.body = .init(stream: { writer in
                Task {
                    do {
                        for try await progress in progressStream {
                            let json = "{\"status\": \"\(progress.replacingOccurrences(of: "\"", with: "\\\""))\"}"  // Docker style
                            _ = try? await writer.write(.buffer(ByteBuffer(string: json + "\n")))
                        }
                        await writer.write(.end)
                    } catch {
                        _ = try? await writer.write(.buffer(ByteBuffer(string: "{\"error\": \"\(error.localizedDescription)\"}\n")))
                        await writer.write(.error(error))
                    }
                }
            })
            return response
        }
    }
}
