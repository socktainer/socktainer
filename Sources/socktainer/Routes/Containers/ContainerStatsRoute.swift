import ContainerAPIClient
import Foundation
import Vapor

struct ContainerStatsRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET, pattern: "/containers/{id}/stats", use: ContainerStatsRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing container ID")
        }

        let stream = (req.query["stream"] as String?) != "false"
        let client = ContainerClient()

        // Verify container exists before starting to stream
        guard (try? await client.get(id: id)) != nil else {
            throw Abort(.notFound, reason: "No such container: \(id)")
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")

        let body = Response.Body { writer in
            Task.detached {
                defer { _ = writer.write(.end) }

                do {
                    var prevSample = try await client.stats(id: id)
                    var prevRead = Date()

                    if stream {
                        // Streaming mode: emit one JSON object per second indefinitely
                        // until the client disconnects or the container stops.
                        while true {
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                            guard let currSample = try? await client.stats(id: id) else { break }
                            let currRead = Date()
                            let stats = RESTContainerStats.build(
                                id: id, prev: prevSample, curr: currSample,
                                prevRead: prevRead, currRead: currRead)
                            if let data = try? JSONEncoder().encode(stats) {
                                var buf = sharedAllocator.buffer(capacity: data.count + 1)
                                buf.writeBytes(data)
                                buf.writeString("\n")
                                _ = writer.write(.buffer(buf))
                            }
                            prevSample = currSample
                            prevRead = currRead
                        }
                    } else {
                        // One-shot mode: take two samples 1s apart to get a CPU delta,
                        // then return a single JSON object and close.
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        guard let currSample = try? await client.stats(id: id) else { return }
                        let currRead = Date()
                        let stats = RESTContainerStats.build(
                            id: id, prev: prevSample, curr: currSample,
                            prevRead: prevRead, currRead: currRead)
                        if let data = try? JSONEncoder().encode(stats) {
                            var buf = sharedAllocator.buffer(capacity: data.count)
                            buf.writeBytes(data)
                            _ = writer.write(.buffer(buf))
                        }
                    }
                } catch {
                    // Container gone or stats unavailable — close stream cleanly
                }
            }
        }

        return Response(status: .ok, headers: headers, body: body)
    }
}
