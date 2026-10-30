import Vapor

struct LibpodContainerListRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        let client = self.client
        let handler = LibpodAdapter.reshaping(ContainerListRoute.handler(client: client), prepare: Self.prepare) { body, _ in
            // Docker's summary has no start time, which podman needs to render "Up 2 hours".
            var startedAt: [String: Double] = [:]
            for container in try await client.list(showAll: true, filters: [:]) {
                // The snapshot's start date can be absent for a container that has been running
                // a long time; fall back to its creation date rather than reporting the epoch.
                let started = container.startedDate ?? AppleContainerTimestampResolver.containerCreationDate(container)
                if let started { startedAt[DockerContainerID.hexId(for: container)] = started.timeIntervalSince1970 }
            }
            return LibpodSchema.containerList(body, startedAt: startedAt)
        }
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/json", use: handler)
    }

    /// `podman ps -n`/`--last` may send `last`; Docker-compat reads `limit`. podman's own server
    /// accepts `last` as an alias that overrides `limit`, so it wins here too.
    @Sendable static func prepare(_ req: Request) -> Request {
        if let last = req.query[String.self, at: "last"] {
            LibpodAdapter.setQuery(req, "limit", to: last)
        }
        return req
    }
}
