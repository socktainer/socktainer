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
        let resolvedName = (createRequest.Name?.isEmpty == false) ? createRequest.Name! : "volume-\(UUID().uuidString)"

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

        let restRequest = RESTVolumeCreate(
            Name: resolvedName,
            Driver: createRequest.Driver ?? "local",
            Options: driverOpts,
            Labels: labels
        )
        // Docker Engine API: POST /volumes/create returns 201 Created.
        let volume: Volume
        do {
            volume = try await client.create(request: restRequest)
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
        }
        let httpResponse = try await volume.encodeResponse(for: req)
        httpResponse.status = .created
        return httpResponse
    }
}
