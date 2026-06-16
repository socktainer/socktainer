import ContainerAPIClient
import Vapor

struct ContainerDeleteRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .DELETE, pattern: "/containers/{id}", use: ContainerDeleteRoute.handler(client: client))
    }

}

extension ContainerDeleteRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let snapshot = try? await client.getContainer(id: id)
            let cached = await ContainerInfoCache.shared.get(id: id)

            let eventImage = snapshot?.configuration.image.reference ?? cached?.image ?? ""
            let eventName = snapshot?.id ?? cached?.nativeId ?? id
            let eventLabels =
                snapshot.map { LabelNormalization.restore($0.configuration.labels) }
                ?? cached?.labels ?? [:]

            func broadcastRemove() async {
                await ContainerInfoCache.shared.remove(id: id)
                guard let broadcaster = req.application.storage[EventBroadcasterKey.self] else { return }
                await broadcaster.broadcast(
                    DockerEvent.simpleEvent(
                        id: id, type: "container", status: "remove",
                        image: eventImage, name: eventName, labels: eventLabels
                    ))
            }

            do {
                let container = try await client.getContainer(id: id)

                if let healthManager = req.application.storage[HealthCheckManagerKey.self] {
                    if container == nil {
                        req.logger.warning("healthcheck stop: container not found for id \(id), falling back — loop may be orphaned")
                    }
                    await healthManager.stop(containerId: container?.id ?? id)
                }

                if let container,
                    let dnsServer = req.application.storage[SocktainerDNSServerKey.self]
                {
                    let containerIP = container.networks.first?.ipv4Address.address.description

                    // Only unregister an alias when this container still owns it — i.e. the
                    // registered IP matches ours. If another container has since claimed the
                    // same hostname (e.g. a second project with an identically-named service),
                    // leave the entry intact so that surviving container keeps resolving.
                    func unregisterIfOwned(_ hostname: String) {
                        let registered = dnsServer.listEntries()[SocktainerDNSServer.normalize(hostname)]
                        if let containerIP, registered != nil, registered != containerIP { return }
                        dnsServer.unregister(hostname: hostname)
                    }

                    if let namesLabel = container.configuration.labels["socktainer.dns.names"] {
                        for name in namesLabel.split(separator: ",").map(String.init) where !name.isEmpty {
                            unregisterIfOwned(name)
                        }
                    }
                    if let serviceName = container.configuration.labels["com.docker.compose.service"],
                        !serviceName.isEmpty
                    {
                        unregisterIfOwned(serviceName)
                        if let projectName = container.configuration.labels["com.docker.compose.project"],
                            !projectName.isEmpty
                        {
                            unregisterIfOwned("\(serviceName).\(projectName)")
                        }
                    }
                }

                if let container, container.status == .running {
                    try await client.stop(id: id, signal: nil, timeout: nil)
                }
                try await client.delete(id: id)
            } catch ClientContainerError.notFound {
                if snapshot != nil || cached != nil {
                    await broadcastRemove()
                }
                throw Abort(.notFound, reason: "No such container: \(id)")
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                let matchList = matches.joined(separator: ", ")
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matchList)")
            }

            await broadcastRemove()
            return .ok
        }
    }
}
