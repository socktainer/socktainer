import Foundation
import NIOCore
import Vapor

/// `GET /libpod/containers/stats` — what `podman stats` calls: several containers per request,
/// answered as one `ContainerStatsReport` per interval (or a single one with `stream=false`).
/// Each container is sampled through the Docker-compat stats handler.
struct LibpodContainersStatsRoute: RouteCollection {
    let client: ClientContainerProtocol
    let dockerRoute: ContainerStatsRoute

    init(client: ClientContainerProtocol) {
        self.client = client
        self.dockerRoute = ContainerStatsRoute(client: client)
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/stats", use: handler())
    }

    private func handler() -> @Sendable (Request) async throws -> Response {
        let client = self.client
        let docker = ContainerStatsRoute.handler(client: client, sample: dockerRoute.sample, sampleInterval: dockerRoute.sampleInterval)
        return { req in
            let items = URLComponents(string: "?" + (req.url.query ?? ""))?.queryItems ?? []
            var references = items.filter { $0.name == "containers" }.compactMap(\.value)
            let stream = (req.query["stream"] as Bool?) ?? true
            let interval = max((req.query["interval"] as Int?) ?? 5, 1)
            // A bare `podman stats` names no containers and means every running one (`all` only
            // adds stopped containers, which have no stats to sample here).
            if references.isEmpty {
                references = try await client.list(showAll: false, filters: [:]).map(\.id)
            }
            let requested = references

            @Sendable func report() async throws -> ByteBuffer {
                let samples = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                    for (index, reference) in requested.enumerated() {
                        group.addTask {
                            let sub = LibpodAdapter.subrequest(of: req, parameter: "id", value: reference)
                            LibpodAdapter.setQuery(sub, "stream", to: "false")
                            let response = try await docker(sub)
                            guard let body = await LibpodAdapter.jsonBody(of: response, on: req) as? [String: Any] else {
                                throw Abort(.internalServerError, reason: "no stats for \(reference): is the container running?")
                            }
                            let stats = LibpodSchema.containerStats(body, containerID: body["id"] as? String ?? reference)
                            return (index, try JSONSerialization.data(withJSONObject: stats))
                        }
                    }
                    var collected: [(Int, Data)] = []
                    for try await sample in group { collected.append(sample) }
                    return try collected.sorted { $0.0 < $1.0 }.map { try JSONSerialization.jsonObject(with: $0.1) }
                }
                let data = try JSONSerialization.data(withJSONObject: ["Error": NSNull(), "Stats": samples] as [String: Any])
                var buffer = ByteBuffer(data: data)
                buffer.writeString("\n")
                return buffer
            }

            // The first sample is taken before any header goes out, so an unknown container is a
            // real 404 rather than an empty 200.
            let first = try await report()
            let response = Response(status: .ok)
            response.headers.contentType = .json
            guard stream else {
                response.body = .init(buffer: first)
                return response
            }
            response.body = .init(asyncStream: { writer in
                try await writer.write(.buffer(first))
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(interval))
                    do { try await writer.write(.buffer(try await report())) } catch { break }
                }
                try await writer.write(.end)
            })
            return response
        }
    }
}
