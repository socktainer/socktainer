import Vapor

struct LibpodContainerListRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        let client = self.client
        let handler = LibpodAdapter.reshaping(ContainerListRoute.handler(client: client)) { body, _ in
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
}
