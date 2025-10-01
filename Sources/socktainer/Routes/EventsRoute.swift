import ContainerClient
import Vapor

struct EventsRoute: RouteCollection {
    let client: ClientHealthCheckProtocol
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "events", use: EventsRoute.handler(client: client))
        routes.get("events", use: EventsRoute.handler(client: client))
    }

}

extension EventsRoute {
    static func handler(client: ClientHealthCheckProtocol) -> @Sendable (Request) async throws -> Response {
        { req in

            let broadcaster = req.application.storage[EventBroadcasterKey.self]!
            let stream = await broadcaster.stream()

            let response = Response(status: .ok)
            response.headers.add(name: .contentType, value: "application/json")

            response.body = .init(stream: { writer in
                Task {
                    for await event in stream {
                        if let json = try? JSONEncoder().encode(event) {
                            var buffer = req.application.allocator.buffer(capacity: json.count + 1)
                            buffer.writeBytes(json)
                            buffer.writeString("\n")
                            writer.write(.buffer(buffer)).whenFailure { error in
                                // NOTE: Consider improving logging
                                req.logger.warning("\(event) raised '\(error)'")
                            }
                        }
                    }
                }
            })

            return response

        }
    }
}
