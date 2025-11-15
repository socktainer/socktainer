import Containerization
import Vapor

struct ImagesGetRoute: RouteCollection {
    let client: ClientImageProtocol

    init(client: ClientImageProtocol) {
        self.client = client
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/images/get", use: ImagesGetRoute.handlerMultiple(client: client))
        try routes.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/get", use: ImagesGetRoute.handlerSingle(client: client))
    }

    static func handlerSingle(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let name = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Image name is required")
            }

            let normalizedName = ContainerImageUtility.normalizeImageReference(name)

            return try await saveImages(references: [normalizedName], req: req, client: client)
        }
    }

    static func handlerMultiple(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let names = try? req.query.get([String].self, at: "names")

            guard let names = names, !names.isEmpty else {
                throw Abort(.badRequest, reason: "At least one image name is required in 'names' query parameter")
            }

            let normalizedNames = names.map { ContainerImageUtility.normalizeImageReference($0) }

            return try await saveImages(references: normalizedNames, req: req, client: client)
        }
    }

    private static func saveImages(references: [String], req: Request, client: ClientImageProtocol) async throws -> Response {
        let platformString = try? req.query.get(String.self, at: "platform")
        let platform: Platform? = {
            guard let platformString = platformString else {
                return nil
            }

            do {
                let data = platformString.data(using: .utf8) ?? Data()
                let decoder = JSONDecoder()
                return try decoder.decode(Platform.self, from: data)
            } catch {
                req.logger.warning("Failed to decode platform JSON: \(platformString)")
                return nil
            }
        }()

        guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
            throw Abort(.internalServerError, reason: "AppleContainerAppSupportUrl not configured")
        }

        let tarballPath: URL
        do {
            tarballPath = try await client.save(references: references, platform: platform, appleContainerAppSupportUrl: appleContainerAppSupportUrl, logger: req.logger)
        } catch let error as ClientImageError {
            switch error {
            case .notFound(let id):
                throw Abort(.notFound, reason: id)
            }
        }
        let tempDir = tarballPath.deletingLastPathComponent()

        let response = try await req.fileio.asyncStreamFile(at: tarballPath.path)

        response.headers.contentType = HTTPMediaType(type: "application", subType: "x-tar")

        Task {
            try? await Task.sleep(for: .seconds(5))
            try? FileManager.default.removeItem(at: tempDir)
        }

        return response
    }
}
