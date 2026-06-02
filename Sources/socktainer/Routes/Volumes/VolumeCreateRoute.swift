import Vapor

struct VolumeCreateRoute: RouteCollection {
    let client: ClientVolumeService
    init(client: ClientVolumeService) {
        self.client = client
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/volumes/create", use: self.handler)
    }

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
            // with external volumes). Fall back to returning the existing
            // volume; rethrow if it's a different failure.
            if let existing = try? await client.inspect(name: resolvedName) {
                return existing
            }
            throw error
        }
    }
}
