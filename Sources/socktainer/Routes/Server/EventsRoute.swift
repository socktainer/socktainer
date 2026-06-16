import ContainerAPIClient
import NIOCore
import Vapor

struct EventsRoute: RouteCollection {
    let client: ClientHealthCheckProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/events", use: EventsRoute.handler(client: client))
    }

}

extension EventsRoute {
    static func handler(client: ClientHealthCheckProtocol) -> @Sendable (Request) async throws -> Response {
        { req in

            guard let broadcaster = req.application.storage[EventBroadcasterKey.self] else {
                throw Abort(.internalServerError, reason: "EventBroadcaster not configured")
            }
            let stream = await broadcaster.stream()

            let response = Response(status: .ok)
            response.headers.add(name: .contentType, value: "application/json")

            response.body = .init(asyncStream: { writer in
                for await event in stream {
                    if let json = try? JSONEncoder().encode(event) {
                        var buffer = req.application.allocator.buffer(capacity: json.count + 1)
                        buffer.writeBytes(json)
                        buffer.writeString("\n")
                        do {
                            try await writer.write(.buffer(buffer))
                        } catch is IOError {
                            req.logger.debug("Client disconnected (broken pipe)")
                            break
                        } catch let error as ChannelError where error == .ioOnClosedChannel {
                            req.logger.debug("Client disconnected (closed channel)")
                            break
                        } catch {
                            req.logger.warning("\(event) raised '\(error)'")
                        }
                    }
                }
                _ = try? await writer.write(.end)
            })

            return response

        }
    }
}
