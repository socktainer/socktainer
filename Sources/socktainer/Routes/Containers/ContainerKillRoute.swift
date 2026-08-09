import ContainerAPIClient
import ContainerResource
import Vapor

struct ContainerKillQuery: Content {
    let signal: String?
}

struct ContainerKillRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/kill", use: ContainerKillRoute.handler(client: client))
    }
}

extension ContainerKillRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in

            let query = try req.query.decode(ContainerKillQuery.self)

            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Container ID is required")
            }

            let signal = query.signal ?? nil
            let snapshot = try? await client.getContainer(id: containerId)

            do {
                try await client.kill(id: containerId, signal: signal)
                if let nativeID = snapshot?.id {
                    // Docker's kill endpoint also sends non-terminating signals
                    // such as SIGHUP and SIGCONT. Retire listeners only when the
                    // signal actually stopped (or removed) the native object.
                    let stopped: Bool
                    do {
                        stopped = try await client.getContainer(id: nativeID)?.status != .running
                    } catch ClientContainerError.notFound {
                        stopped = true
                    } catch {
                        stopped = false
                    }
                    if stopped {
                        await req.application.storage[PublishedPortManagerKey.self]?.close(
                            nativeID: nativeID
                        )
                    }
                }
                if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                    let dockerName: String
                    if let snapshot {
                        dockerName = await DockerContainerMetadataStore.shared.name(nativeID: snapshot.id)
                    } else {
                        dockerName = containerId
                    }
                    // moby's kill event carries the numeric signal in {"signal": <int>}.
                    // Docker defaults to SIGKILL when no signal is given.
                    let signalNumber = (try? parseSignal(signal ?? "SIGKILL")) ?? SIGKILL
                    let event = DockerEvent.simpleEvent(
                        id: snapshot.map { DockerContainerID.hexId(for: $0) } ?? containerId,
                        type: "container",
                        status: "kill",
                        image: snapshot.map {
                            ContainerImageIdentity.requestedReference(for: $0)
                        } ?? "",
                        name: dockerName,
                        labels: snapshot.map {
                            ContainerImageIdentity.dockerLabels(for: $0)
                        } ?? [:],
                        extraAttributes: ["signal": String(signalNumber)]
                    )
                    await broadcaster.broadcast(event)
                }
                return Response(status: .noContent)
            } catch ClientContainerError.notFound {
                return Response(status: .notFound, body: .init(string: "container \(containerId) not found"))
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                let matchList = matches.joined(separator: ", ")
                return Response(status: .badRequest, body: .init(string: "ambiguous container reference \(reference): matches \(matchList)"))
            } catch ClientContainerError.notRunning {
                return Response(status: .conflict, body: .init(string: "container \(containerId) is not running"))
            } catch {
                req.logger.error("Failed to kill container \(containerId): \(error)")
                return Response(status: .internalServerError, body: .init(string: "Failed to kill container: \(error)"))
            }
        }
    }
}
