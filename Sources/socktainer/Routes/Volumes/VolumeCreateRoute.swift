import ContainerResource
import Vapor

/// Route collection for the Docker `POST /volumes/create` endpoint.
struct VolumeCreateRoute: RouteCollection {
    let client: ClientVolumeService

    /// Registers the `POST /volumes/create` route on the given builder.
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/volumes/create", use: self.handler)
    }

    /// Creates a volume, returning the existing volume when one with the same
    /// name already exists (idempotent, matching Docker's `POST /volumes/create`).
    func handler(_ req: Request) async throws -> Response {
        let createRequest = try req.content.decode(VolumeRequest.self)
        let isAnonymous = createRequest.Name?.isEmpty != false
        let resolvedName = isAnonymous ? "volume-\(UUID().uuidString)" : createRequest.Name!

        // Strip `sync` from DriverOpts (Apple Container ignores it, but it's
        // Socktainer-specific) and persist it as a label so ContainerCreateRoute
        // can apply the right Filesystem.SyncMode when mounting this volume.
        var driverOpts = createRequest.DriverOpts ?? [:]
        let originalLabels = createRequest.Labels ?? [:]
        guard !LabelNormalization.containsReservedKey(originalLabels) else {
            throw Abort(.badRequest, reason: "Label key '\(LabelNormalization.mappingKey)' is reserved for internal use")
        }
        var labels = LabelNormalization.sanitize(originalLabels)
        if let mapping = LabelNormalization.buildMapping(originalLabels) {
            labels[LabelNormalization.mappingKey] = mapping
        }
        if let syncValue = driverOpts.removeValue(forKey: "sync") {
            guard Filesystem.SyncMode(rawString: syncValue) != nil else {
                throw Abort(.badRequest, reason: "Invalid sync mode '\(syncValue)'. Valid values: nosync, fsync, full")
            }
            labels[Filesystem.SyncMode.socktainerLabel] = syncValue
        }
        if isAnonymous {
            // moby marks nameless creates anonymous so that volume prune
            // (without all=true) targets only them. Also stamp Apple's own
            // anonymous label so `container volume ls` agrees.
            labels[ClientVolumeService.anonymousVolumeLabel] = ""
            labels[VolumeConfiguration.anonymousLabel] = ""
        }

        let restRequest = RESTVolumeCreate(
            Name: resolvedName,
            Driver: createRequest.Driver ?? "local",
            Options: driverOpts,
            Labels: labels
        )
        // Docker Engine API: POST /volumes/create returns 201 Created.
        let volume: Volume
        let created: Bool
        do {
            volume = try await client.create(request: restRequest)
            created = true
        } catch {
            // Docker's `volume create` is idempotent: creating a volume that
            // already exists returns the existing one rather than erroring.
            // socktainer's create throws "already exists", which breaks tools
            // that create-to-ensure a volume exists (e.g. `docker compose up`
            // with external volumes). Only treat that specific conflict as
            // idempotent — return the existing volume; any other failure is a
            // real error and must propagate.
            guard "\(error)".lowercased().contains("already exists") else { throw error }
            volume = try await client.inspect(name: resolvedName)
            created = false
        }
        // Only emit "create" for a genuinely new volume — moby logs the create event
        // only when the store actually created one, not on the idempotent return path.
        if created, let broadcaster = req.application.storage[EventBroadcasterKey.self] {
            // moby volume events carry {driver} with the volume name as Actor.ID.
            await broadcaster.broadcast(
                DockerEvent.make(
                    type: "volume", action: "create", actorID: volume.Name,
                    attributes: ["driver": volume.Driver]))
        }
        let httpResponse = try await volume.encodeResponse(for: req)
        httpResponse.status = .created
        return httpResponse
    }
}
