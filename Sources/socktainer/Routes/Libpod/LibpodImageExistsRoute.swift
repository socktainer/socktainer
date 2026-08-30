import ContainerAPIClient
import ContainerPersistence
import ContainerizationError
import Vapor

struct LibpodImageExistsRoute: RouteCollection {
    let systemConfig: ContainerSystemConfig

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/images/{name:.*}/exists", use: LibpodImageExistsRoute.handler(systemConfig: systemConfig))
    }

    static func handler(systemConfig: ContainerSystemConfig) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let refOrId = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }
            do {
                _ = try await ClientImage.get(reference: refOrId, containerSystemConfig: systemConfig)
            } catch let error as ContainerizationError where error.code == .notFound {
                throw Abort(.notFound, reason: "No such image: \(refOrId)")
            }
            return Response(status: .noContent)
        }
    }
}
