import ContainerAPIClient
import ContainerPersistence
import Vapor

struct LibpodInfoRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let imageClient: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        let containerClient = self.containerClient
        let imageClient = self.imageClient
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/info") { req in
            try await InfoRoute.handle(
                req,
                containerClient: containerClient,
                imageClient: imageClient,
                configLoader: { try await ConfigurationLoader.load() },
                systemHealthProvider: {
                    let health = try await ClientHealthCheck.ping()
                    return (health.appRoot.path, health.apiServerVersion)
                },
                kernelNameProvider: { try await getLinuxDefaultKernelName() }
            )
        }
    }
}
