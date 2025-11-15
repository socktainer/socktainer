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
        let volume = try await client.create(request: restRequest)
        return volume
    }
}
