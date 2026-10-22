import Vapor

/// `GET /libpod/containers/{id}/stats` shares the Docker-compat route's handler and sampling.
struct LibpodContainerStatsRoute: RouteCollection {
    let dockerRoute: ContainerStatsRoute

    init(client: ClientContainerProtocol) {
        self.dockerRoute = ContainerStatsRoute(client: client)
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET, pattern: "/libpod/containers/{id}/stats",
            use: ContainerStatsRoute.handler(client: dockerRoute.client, sample: dockerRoute.sample, sampleInterval: dockerRoute.sampleInterval))
    }
}
