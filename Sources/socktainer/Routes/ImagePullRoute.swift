import Foundation
import Vapor

struct ImagePullRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "images", "create", use: ImagePullRoute.handler(client: client))
    }
}

extension ImagePullRoute {
    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let image = req.query[String.self, at: "fromImage"] ?? ""
            let tag = req.query[String.self, at: "tag"]
            let platformString = req.query[String.self, at: "platform"]
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
