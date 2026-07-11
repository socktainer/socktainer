import ContainerAPIClient
import ContainerResource
import Foundation
import Vapor

struct ContainerExportRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let archiveClient: ClientArchiveProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET,
            pattern: "/containers/{id}/export",
            use: ContainerExportRoute.handler(containerClient: containerClient, archiveClient: archiveClient)
        )
    }

    static func handler(
        containerClient: ClientContainerProtocol,
        archiveClient: ClientArchiveProtocol
    ) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let reference = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let resolved: ContainerSnapshot?
            do {
                resolved = try await containerClient.getContainer(id: reference)
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matches.joined(separator: ", "))")
            }
            guard let container = resolved else {
                throw Abort(.notFound, reason: "No such container: \(reference)")
            }

            let tarPath: URL
            do {
                tarPath = try await archiveClient.exportRootfs(containerId: container.id)
            } catch let error as ClientArchiveError {
                switch error {
                case .rootfsNotFound:
                    throw Abort(.notFound, reason: error.localizedDescription)
                default:
                    throw Abort(.internalServerError, reason: "Error exporting container \(reference): \(error.localizedDescription)")
                }
            }

            let broadcaster = req.application.storage[EventBroadcasterKey.self]
            let response: Response
            do {
                response = try await req.fileio.asyncStreamFile(at: tarPath.path) { result in
                    try? FileManager.default.removeItem(at: tarPath)
                    // moby logs the export event only once the copy completed.
                    if case .success = result, let broadcaster {
                        await broadcaster.broadcast(
                            DockerEvent.simpleEvent(
                                id: DockerContainerID.hexId(for: container),
                                type: "container",
                                status: "export",
                                image: container.configuration.image.reference,
                                name: container.id,
                                labels: LabelNormalization.restore(container.configuration.labels)
                            ))
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: tarPath)
                throw error
            }
            response.headers.contentType = HTTPMediaType(type: "application", subType: "octet-stream")
            return response
        }
    }
}
