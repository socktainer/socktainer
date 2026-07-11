import ContainerResource
import Vapor

struct ContainerUpdateRequest: Content {
    let RestartPolicy: RestartPolicy?
    let Memory: Int64?
    let MemorySwap: Int64?
    let MemoryReservation: Int64?
    let NanoCpus: Int64?
    let CpuShares: Int64?
    let CpuPeriod: Int64?
    let CpuQuota: Int64?
    let CpusetCpus: String?
    let PidsLimit: Int64?
    let BlkioWeight: Int?
}

struct ContainerUpdateResponse: Content {
    let Warnings: [String]
}

struct ContainerUpdateRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/update", use: ContainerUpdateRoute.handler(client: client))
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }
            let container: ContainerSnapshot
            do {
                guard let found = try await client.getContainer(id: containerId) else {
                    throw Abort(.notFound, reason: "No such container: \(containerId)")
                }
                container = found
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matches.joined(separator: ", "))")
            }

            let body = try req.content.decode(ContainerUpdateRequest.self)
            let fixedResources = Self.requestedFixedResources(body)

            guard let policy = body.RestartPolicy, !policy.Name.isEmpty else {
                guard fixedResources.isEmpty else {
                    throw Abort(
                        .badRequest,
                        reason: "Cannot update \(fixedResources.joined(separator: ", ")): Apple Container VM resources are fixed at create time")
                }
                throw Abort(.badRequest, reason: "Nothing to update: no updatable fields in request")
            }

            if let error = RestartPolicyManager.validatePolicy(policy) {
                throw Abort(.badRequest, reason: error)
            }

            await RestartPolicyOverrideStore.shared.set(id: DockerContainerID.hexId(for: container), policy: policy)

            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                await broadcaster.broadcast(
                    DockerEvent.simpleEvent(
                        id: DockerContainerID.hexId(for: container),
                        type: "container",
                        status: "update",
                        image: container.configuration.image.reference,
                        name: container.id,
                        labels: LabelNormalization.restore(container.configuration.labels)
                    ))
            }

            var warnings: [String] = []
            if !fixedResources.isEmpty {
                warnings.append("Ignored \(fixedResources.joined(separator: ", ")): Apple Container VM resources are fixed at create time")
            }
            return try await ContainerUpdateResponse(Warnings: warnings).encodeResponse(status: .ok, for: req)
        }
    }

    static func requestedFixedResources(_ body: ContainerUpdateRequest) -> [String] {
        var fields: [String] = []
        if let value = body.Memory, value != 0 { fields.append("Memory") }
        if let value = body.MemorySwap, value != 0 { fields.append("MemorySwap") }
        if let value = body.MemoryReservation, value != 0 { fields.append("MemoryReservation") }
        if let value = body.NanoCpus, value != 0 { fields.append("NanoCpus") }
        if let value = body.CpuShares, value != 0 { fields.append("CpuShares") }
        if let value = body.CpuPeriod, value != 0 { fields.append("CpuPeriod") }
        if let value = body.CpuQuota, value != 0 { fields.append("CpuQuota") }
        if let value = body.CpusetCpus, !value.isEmpty { fields.append("CpusetCpus") }
        // PidsLimit is moby's one pointer resource: 0/-1 mean unlimited, null means no change.
        if body.PidsLimit != nil { fields.append("PidsLimit") }
        if let value = body.BlkioWeight, value != 0 { fields.append("BlkioWeight") }
        return fields
    }
}
