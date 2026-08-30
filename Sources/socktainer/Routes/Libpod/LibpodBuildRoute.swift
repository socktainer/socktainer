import ContainerPersistence
import Vapor

struct LibpodBuildRoute: RouteCollection {
    let client: ClientContainerProtocol
    let builderClient: ClientBuilderProtocol
    let systemConfig: ContainerSystemConfig
    let manifestClient: ClientManifestServiceProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .POST, pattern: "/libpod/build", use: BuildRoute.handler(client: client, builderClient: builderClient, systemConfig: systemConfig, manifestClient: manifestClient))
    }
}
