import ContainerAPIClient
import ContainerPersistence
import Vapor

struct LibpodInfoRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let imageClient: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        let containerClient = self.containerClient
        let imageClient = self.imageClient
        let handler = LibpodAdapter.reshaping(
            { (req: Request) in
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
            } as @Sendable (Request) async throws -> Response
        ) { body, _ in LibpodSchema.info(body) }
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/info", use: handler)
    }
}
