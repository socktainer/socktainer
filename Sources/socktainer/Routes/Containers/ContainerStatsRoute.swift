import ContainerAPIClient
import ContainerResource
import Foundation
import Vapor

struct ContainerStatsRoute: RouteCollection {
    let client: ClientContainerProtocol
    /// Takes one stats sample for a container by its native ID.
    let sample: @Sendable (String) async throws -> ContainerResource.ContainerStats
    /// Time between the two samples a CPU delta is computed from.
    let sampleInterval: Duration

    init(
        client: ClientContainerProtocol,
        sample: @escaping @Sendable (String) async throws -> ContainerResource.ContainerStats = {
            try await ContainerClient().stats(id: $0)
        },
        sampleInterval: Duration = .seconds(1)
    ) {
        self.client = client
        self.sample = sample
        self.sampleInterval = sampleInterval
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET, pattern: "/containers/{id}/stats",
            use: ContainerStatsRoute.handler(client: client, sample: sample, sampleInterval: sampleInterval))
    }
}

extension ContainerStatsRoute {
    static func handler(
        client: ClientContainerProtocol,
        sample: @escaping @Sendable (String) async throws -> ContainerResource.ContainerStats,
        sampleInterval: Duration
    ) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let reference = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let stream = MobyBool.queryValue(req.query["stream"] as String?, defaultingTo: true)

            // Resolve the reference the way the other container routes do, so a
            // Docker-shaped ID or ID prefix (as `docker ps` and `docker stats`
            // with no arguments pass it) finds the container, not just its name.
            let container: ContainerSnapshot
            do {
                guard let found = try await client.getContainer(id: reference) else {
                    throw Abort(.notFound, reason: "No such container: \(reference)")
                }
                container = found
            } catch ClientContainerError.ambiguousId(let ambiguousReference, let matches) {
                let matchList = matches.joined(separator: ", ")
                throw Abort(
                    .badRequest, reason: "ambiguous container reference \(ambiguousReference): matches \(matchList)")
            }
            let nativeId = container.id
            let dockerId = DockerContainerID.hexId(for: container)
            let name = "/" + container.id

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")

            let body = Response.Body { writer in
                Task.detached {
                    defer { _ = writer.write(.end) }

                    do {
                        var prevSample = try await sample(nativeId)
                        var prevRead = Date()

                        if stream {
                            // Streaming mode: emit one JSON object per interval indefinitely
                            // until the client disconnects or the container stops.
                            while true {
                                try await Task.sleep(for: sampleInterval)
                                guard let currSample = try? await sample(nativeId) else { break }
                                let currRead = Date()
                                let stats = RESTContainerStats.build(
                                    id: dockerId, name: name, prev: prevSample, curr: currSample,
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
                            // One-shot mode: take two samples one interval apart to get a
                            // CPU delta, then return a single JSON object and close.
                            try await Task.sleep(for: sampleInterval)
                            guard let currSample = try? await sample(nativeId) else { return }
                            let currRead = Date()
                            let stats = RESTContainerStats.build(
                                id: dockerId, name: name, prev: prevSample, curr: currSample,
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
}
