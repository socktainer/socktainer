import ContainerAPIClient
import Foundation
import Vapor

struct ContainerStatsRoute: RouteCollection {
    let client: ContainerStatsClientProtocol
    let sampleIntervalNanoseconds: UInt64

    init(
        client: ContainerStatsClientProtocol,
        sampleIntervalNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.client = client
        self.sampleIntervalNanoseconds = sampleIntervalNanoseconds
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET,
            pattern: "/containers/{id}/stats",
            use: ContainerStatsRoute.handler(
                client: client,
                sampleIntervalNanoseconds: sampleIntervalNanoseconds
            )
        )
    }

    static func handler(
        client: ContainerStatsClientProtocol,
        sampleIntervalNanoseconds: UInt64 = 1_000_000_000
    ) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let stream = MobyBool.queryValue(req.query["stream"] as String?, defaultingTo: true)
            let oneShot = MobyBool.queryValue(req.query["one-shot"] as String?, defaultingTo: false)

            // Resolve the Docker-facing name, full ID, or short ID once. Apple's
            // stats API only accepts the immutable native container ID.
            guard let container = try await client.getContainer(id: id) else {
                throw Abort(.notFound, reason: "No such container: \(id)")
            }
            let nativeID = container.id
            let name = await DockerContainerMetadataStore.shared.name(nativeID: nativeID)

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")

            let body = Response.Body { writer in
                Task.detached {
                    defer { _ = writer.write(.end) }

                    do {
                        var prevSample = try await client.stats(nativeID: nativeID)
                        var prevRead = Date()

                        if stream && !oneShot {
                            // Streaming mode: emit one JSON object per second indefinitely
                            // until the client disconnects or the container stops.
                            while true {
                                try await Task.sleep(nanoseconds: sampleIntervalNanoseconds)
                                guard let currSample = try? await client.stats(nativeID: nativeID) else { break }
                                let currRead = Date()
                                let stats = RESTContainerStats.build(
                                    id: id, name: name, prev: prevSample, curr: currSample,
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
                            try await Task.sleep(nanoseconds: sampleIntervalNanoseconds)
                            guard let currSample = try? await client.stats(nativeID: nativeID) else { return }
                            let currRead = Date()
                            let stats = RESTContainerStats.build(
                                id: id, name: name, prev: prevSample, curr: currSample,
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
