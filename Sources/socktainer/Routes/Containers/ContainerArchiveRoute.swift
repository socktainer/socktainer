import ContainerAPIClient
import Foundation
import Vapor

/// Query parameters for GET /containers/{id}/archive
struct ContainerArchiveGetQuery: Content {
    /// Path to a file or directory inside the container
    let path: String
}

/// Query parameters for PUT /containers/{id}/archive
struct ContainerArchivePutQuery: Content {
    /// Path to a directory in the container to extract the archive's contents into
    let path: String
    /// If true, do not overwrite existing directory with non-directory and vice versa
    let noOverwriteDirNonDir: Bool?
    /// If true, copy UID/GID from the source archive
    let copyUIDGID: Bool?
}

struct ContainerArchiveRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let archiveClient: ClientArchiveProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET,
            pattern: "/containers/{id:.*}/archive",
            use: ContainerArchiveRoute.getHandler(containerClient: containerClient, archiveClient: archiveClient)
        )
        try routes.registerVersionedRoute(
            .PUT,
            pattern: "/containers/{id:.*}/archive",
            use: ContainerArchiveRoute.putHandler(containerClient: containerClient, archiveClient: archiveClient)
        )
        try routes.registerVersionedRoute(
            .HEAD,
            pattern: "/containers/{id:.*}/archive",
            use: ContainerArchiveRoute.headHandler(containerClient: containerClient, archiveClient: archiveClient)
        )
    }

    /// GET /containers/{id}/archive - Get a tar archive of a resource in the filesystem of container id
    static func getHandler(
        containerClient: ClientContainerProtocol,
        archiveClient: ClientArchiveProtocol
    ) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerArchiveGetQuery.self)

            // Verify container exists
            guard let container = try await containerClient.getContainer(id: id) else {
                throw Abort(.notFound, reason: "No such container: \(id)")
            }

            do {
                let (tarData, stat) = try await archiveClient.getArchive(containerId: container.id, path: query.path)

                // Create the path stat header (base64 encoded JSON)
                let statJson = try JSONEncoder().encode(stat)
                let statBase64 = statJson.base64EncodedString()

                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/x-tar")
                headers.add(name: "X-Docker-Container-Path-Stat", value: statBase64)

                return Response(
                    status: .ok,
                    headers: headers,
                    body: .init(data: tarData)
                )
            } catch let error as ClientArchiveError {
                switch error {
                case .pathNotFound:
                    throw Abort(.notFound, reason: error.localizedDescription)
                case .rootfsNotFound:
                    throw Abort(.notFound, reason: error.localizedDescription)
                default:
                    throw Abort(.internalServerError, reason: error.localizedDescription)
                }
            }
        }
    }

    /// PUT /containers/{id}/archive - Extract an archive of files or folders to a directory in a container
    static func putHandler(
        containerClient: ClientContainerProtocol,
        archiveClient: ClientArchiveProtocol
    ) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerArchivePutQuery.self)

            // Verify container exists
            guard let container = try await containerClient.getContainer(id: id) else {
                throw Abort(.notFound, reason: "No such container: \(id)")
            }

            // Collect the tar data from request body
            guard let tarBuffer = try await req.body.collect().get() else {
                throw Abort(.badRequest, reason: "Request body is required")
            }
            let tarData = Data(buffer: tarBuffer)

            do {
                try await archiveClient.putArchive(
                    containerId: container.id,
                    path: query.path,
                    tarData: tarData,
                    noOverwriteDirNonDir: query.noOverwriteDirNonDir ?? false
                )

                return Response(status: .ok)
            } catch let error as ClientArchiveError {
                switch error {
                case .pathNotFound:
                    throw Abort(.notFound, reason: error.localizedDescription)
                case .rootfsNotFound:
                    throw Abort(.notFound, reason: error.localizedDescription)
                case .invalidPath:
                    throw Abort(.badRequest, reason: error.localizedDescription)
                default:
                    throw Abort(.internalServerError, reason: error.localizedDescription)
                }
            }
        }
    }

    /// HEAD /containers/{id}/archive - Get information about files in a container
    static func headHandler(
        containerClient: ClientContainerProtocol,
        archiveClient: ClientArchiveProtocol
    ) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerArchiveGetQuery.self)

            // Verify container exists
            guard let container = try await containerClient.getContainer(id: id) else {
                throw Abort(.notFound, reason: "No such container: \(id)")
            }

            do {
                let (_, stat) = try await archiveClient.getArchive(containerId: container.id, path: query.path)

                // Create the path stat header (base64 encoded JSON)
                let statJson = try JSONEncoder().encode(stat)
                let statBase64 = statJson.base64EncodedString()

                var headers = HTTPHeaders()
                headers.add(name: "X-Docker-Container-Path-Stat", value: statBase64)

                return Response(status: .ok, headers: headers)
            } catch let error as ClientArchiveError {
                switch error {
                case .pathNotFound:
                    throw Abort(.notFound, reason: error.localizedDescription)
                case .rootfsNotFound:
                    throw Abort(.notFound, reason: error.localizedDescription)
                default:
                    throw Abort(.internalServerError, reason: error.localizedDescription)
                }
            }
        }
    }
}
