import ContainerClient

protocol ClientContainerProtocol: Sendable {
    func list(showAll: Bool) async throws -> [ClientContainer]
    func getContainer(id: String) async throws -> ClientContainer?

    func start(id: String) async throws
    func stop(id: String) async throws
    func delete(id: String) async throws
}

enum ClientContainerError: Error {
    case notFound(id: String)
}

struct ClientContainerService: ClientContainerProtocol {
    func list(showAll: Bool) async throws -> [ClientContainer] {
        // if showAll return all the list, else return only started containers
        guard showAll else {
            return try await ClientContainer.list().filter { $0.status == .running }
        }
        return try await ClientContainer.list()
    }

    func getContainer(id: String) async throws -> ClientContainer? {
        try await ClientContainer.get(id: id)
    }

    func start(id: String) async throws {
        let container = try await ClientContainer.get(id: id)
        //try await container.createProcess(id: "start", command: ["start"]).start()
    }

    func stop(id: String) async throws {
        let container = try await ClientContainer.list().filter { $0.id == id }.first
        guard let container else {
            throw ClientContainerError.notFound(id: id)
        }
        try await container.stop()
    }

    func delete(id: String) async throws {
        let container = try await ClientContainer.list().filter { $0.id == id }.first
        guard let container else {
            throw ClientContainerError.notFound(id: id)
        }
        try await container.delete()
    }
}
