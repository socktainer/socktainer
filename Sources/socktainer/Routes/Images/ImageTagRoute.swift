import ContainerClient
import Vapor

struct ImageTagRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/{name:.*}/tag", use: ImageTagRoute.handler)
    }
}

struct RESTImageTagQuery: Vapor.Content {
    let repo: String?
    let tag: String?
}

extension ImageTagRoute {
    static func handler(_ req: Request) async throws -> Response {
        guard let sourceImageName = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "Missing image name parameter")
        }

        let query = try req.query.decode(RESTImageTagQuery.self)

        guard let repo = query.repo, !repo.isEmpty else {
            throw Abort(.badRequest, reason: "repo parameter is required")
        }

        let targetReference: String
        if let tag = query.tag, !tag.isEmpty {
            targetReference = "\(repo):\(tag)"
        } else {
            targetReference = "\(repo):latest"
        }

        let sourceImage: ClientImage
        do {
            sourceImage = try await ClientImage.get(reference: sourceImageName)
        } catch {
            throw Abort(.notFound, reason: "No such image: \(sourceImageName)")
        }

        do {
            _ = try await sourceImage.tag(new: targetReference)
            return Response(status: .created)
        } catch {
            req.logger.error("Failed to tag image: \(error)")
            throw Abort(.internalServerError, reason: "Failed to tag image: \(error.localizedDescription)")
        }
    }
}
