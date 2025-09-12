import ContainerClient



struct ClientService: ClientProtocol {
    func ping() async throws {
        try await ClientHealthCheck.ping(timeout: .seconds(1))
    }

    func getContainer(id: String) async throws -> ClientContainer? {
        return try await ClientContainer.get(id: id)
    }

}
