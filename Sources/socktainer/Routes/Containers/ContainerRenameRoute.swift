import Foundation
import Vapor

struct ContainerRenameRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/rename", use: Self.handler(client: client))
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id"), let requestedName = req.query[String.self, at: "name"] else {
                throw Abort(.badRequest, reason: "Missing container ID or name")
            }
            let name = requestedName.hasPrefix("/") ? String(requestedName.dropFirst()) : requestedName
            guard name.range(of: "\\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\\z", options: .regularExpression) != nil else {
                throw Abort(.badRequest, reason: "Invalid container name: \(requestedName)")
            }
            guard let container = try await client.getContainer(id: id) else {
                throw Abort(.notFound, reason: "No such container: \(id)")
            }
            let store = ContainerNameOverrideStore.shared
            return try await store.withAvailableName(name, excluding: container.id, client: client) {
                // Recheck after acquiring the mutation slot: deletion may have happened
                // while this request was queued. Native identity and Docker ID stay intact.
                guard let current = try await client.getContainer(id: DockerContainerID.hexId(for: container)) else {
                    throw Abort(.notFound, reason: "No such container: \(id)")
                }
                let previousName = await store.name(forNativeID: current.id)
                if name == previousName { return .noContent }
                try await store.set(nativeID: current.id, name: name)

                if current.status == .running, let dnsServer = req.application.storage[SocktainerDNSServerKey.self] {
                    let cached = await ContainerInfoCache.shared.get(id: current.id)
                    if let ip = ContainerStartRoute.dnsAttachmentIP(in: current) ?? cached?.ip {
                        dnsServer.unregisterIfOwned(hostname: previousName, expectedIP: ip)
                        ContainerStartRoute.registerDNSAliases(container: current, name: name, ip: ip, dnsServer: dnsServer)
                    }
                }
                if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                    await broadcaster.broadcast(
                        DockerEvent.simpleEvent(
                            id: DockerContainerID.hexId(for: current), type: "container", status: "rename",
                            image: current.configuration.image.reference, name: name,
                            labels: LabelNormalization.restore(current.configuration.labels),
                            extraAttributes: ["oldName": "/" + previousName]))
                }
                return .noContent
            }
        }
    }
}
