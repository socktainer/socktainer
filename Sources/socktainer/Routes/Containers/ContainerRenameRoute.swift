import ContainerResource
import Foundation
import Vapor

struct ContainerRenameRoute: RouteCollection {
    let client: ClientContainerProtocol
    let metadataStore: DockerContainerMetadataStore

    init(
        client: ClientContainerProtocol,
        metadataStore: DockerContainerMetadataStore = .shared
    ) {
        self.client = client
        self.metadataStore = metadataStore
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .POST,
            pattern: "/containers/{id}/rename",
            use: ContainerRenameRoute.handler(client: client, metadataStore: metadataStore)
        )
    }

    struct Query: Content { let name: String }

    static func handler(
        client: ClientContainerProtocol,
        metadataStore: DockerContainerMetadataStore
    ) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let reference = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }
            let query = try req.query.decode(Query.self)
            let requestedName = query.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard
                DockerContainerMetadataStore.isValid(
                    DockerContainerMetadataStore.normalized(requestedName)
                )
            else {
                throw Abort(
                    .badRequest,
                    reason: "Error when allocating new name: Invalid container name (\(requestedName))"
                )
            }

            let container: ContainerSnapshot
            do {
                guard let found = try await client.getContainer(id: reference) else {
                    throw Abort(.notFound, reason: "No such container: \(reference)")
                }
                container = found
            } catch ClientContainerError.ambiguousId(let id, let matches) {
                throw Abort(.badRequest, reason: "ambiguous container reference \(id): matches \(matches.joined(separator: ", "))")
            }

            return try await ContainerIdentityOperationLock.shared.withLock(
                containerID: container.id
            ) {
                let all = try await client.list(showAll: true, filters: [:])
                let dnsServer = req.application.storage[SocktainerDNSServerKey.self]
                let dnsIP =
                    container.status == .running
                    ? ContainerStartRoute.dnsAttachmentIP(in: container)
                    : nil
                let result: (old: String, new: String)
                do {
                    result = try await metadataStore.rename(
                        nativeID: container.id,
                        to: requestedName,
                        existingNativeIDs: Set(all.map(\.id)),
                        onCommit: { oldName, newName in
                            guard let dnsServer, let dnsIP else { return }
                            dnsServer.unregisterIfOwned(
                                hostname: oldName,
                                expectedIP: dnsIP
                            )
                            dnsServer.register(hostname: newName, ip: dnsIP)
                        }
                    )
                } catch DockerContainerMetadataStore.StoreError.nameConflict(let name) {
                    throw Abort(
                        .conflict,
                        reason: "Error when allocating new name: Conflict. The container name \"/\(name)\" is already in use."
                    )
                } catch DockerContainerMetadataStore.StoreError.sameName {
                    throw Abort(.badRequest, reason: "Renaming a container with the same name as its current name")
                } catch DockerContainerMetadataStore.StoreError.invalidName {
                    throw Abort(
                        .badRequest,
                        reason: "Error when allocating new name: Invalid container name (\(requestedName))"
                    )
                }

                if result.old != result.new,
                    let broadcaster = req.application.storage[EventBroadcasterKey.self]
                {
                    await broadcaster.broadcast(
                        DockerEvent.simpleEvent(
                            id: DockerContainerID.hexId(for: container),
                            type: "container",
                            status: "rename",
                            image: ContainerImageIdentity.requestedReference(for: container),
                            name: result.new,
                            labels: ContainerImageIdentity.dockerLabels(for: container),
                            extraAttributes: ["oldName": "/\(result.old)"]
                        )
                    )
                }
                return .noContent
            }
        }
    }
}
