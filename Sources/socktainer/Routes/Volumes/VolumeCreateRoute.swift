import Vapor

struct VolumeCreateRoute: RouteCollection {
    let client: ClientVolumeService
    init(client: ClientVolumeService) {
        self.client = client
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/volumes/create", use: self.handler)
    }

    /// Creates a volume, returning the existing volume when one with the same
    /// name already exists (idempotent, matching Docker's `POST /volumes/create`).
    func handler(_ req: Request) async throws -> Volume {
        let createRequest = try req.content.decode(VolumeRequest.self)
        let resolvedName = (createRequest.Name?.isEmpty == false) ? createRequest.Name! : "volume-\(UUID().uuidString)"
        let restRequest = RESTVolumeCreate(
            Name: resolvedName,
            Driver: createRequest.Driver ?? "local",
            Options: createRequest.DriverOpts ?? [:],
            Labels: createRequest.Labels ?? [:]
        )
        do {
            return try await client.create(request: restRequest)
        } catch {
            // Docker's `volume create` is idempotent: creating a volume that
            // already exists returns the existing one rather than erroring.
            // socktainer's create throws "already exists", which breaks tools
            // that create-to-ensure a volume exists (e.g. `docker compose up`
            // with external volumes). Only treat that specific conflict as
            // idempotent — return the existing volume; any other failure is a
            // real error and must propagate.
            guard "\(error)".lowercased().contains("already exists") else { throw error }
            return try await client.inspect(name: resolvedName)
        }
    }
}
