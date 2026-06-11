import Foundation
import Vapor

public enum ContainerWaitCondition: String, CaseIterable, Codable, Sendable {
    case notRunning = "not-running"
    case nextExit = "next-exit"
    case removed = "removed"

    public static let `default`: ContainerWaitCondition = .notRunning
}

struct ContainerWaitRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/wait", use: ContainerWaitRoute.handler(client: client))
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let conditionString = req.query["condition"] as String?
            let condition: ContainerWaitCondition
            if let conditionString = conditionString {
                condition = ContainerWaitCondition(rawValue: conditionString) ?? ContainerWaitCondition.default
            } else {
                condition = ContainerWaitCondition.default
            }

            // Preflight before flushing headers so a missing container returns a
            // real 404 instead of a streamed `200 {"StatusCode":0}` — the latter
            // would make "no such container" indistinguishable from a clean exit.
            guard try await client.getContainer(id: containerId) != nil else {
                throw Abort(.notFound, reason: "No such container: \(containerId)")
            }

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")

            // `docker run` reads the /wait response HEAD before it sends /start,
            // then reads the body once the container exits. If we withhold the
            // head until the body is ready (the default when returning a Content
            // value), /start is never sent and the run deadlocks. So flush the
            // head immediately with an empty write, then stream the exit-code
            // JSON once client.wait() resolves (it blocks until the init process
            // actually exits and its real code is recorded).
            let body = Response.Body { writer in
                Task.detached {
                    defer { _ = writer.write(.end) }

                    _ = writer.write(.buffer(sharedAllocator.buffer(capacity: 0)))

                    let result: RESTContainerWait
                    do {
                        result = try await client.wait(id: containerId, condition: condition)
                    } catch {
                        // Emit a 0-status body so the client unblocks rather than
                        // hanging on a half-open stream.
                        result = RESTContainerWait(statusCode: 0)
                    }

                    if let data = try? JSONEncoder().encode(result) {
                        var buf = sharedAllocator.buffer(capacity: data.count)
                        buf.writeBytes(data)
                        _ = writer.write(.buffer(buf))
                    }
                }
            }

            return Response(status: .ok, headers: headers, body: body)
        }
    }
}
