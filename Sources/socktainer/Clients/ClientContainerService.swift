import ContainerClient
import Foundation

protocol ClientContainerProtocol: Sendable {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ClientContainer]
    func getContainer(id: String) async throws -> ClientContainer?
    func enforceContainerRunning(container: ClientContainer) throws

    func start(id: String, detach: Bool) async throws
    func stop(id: String) async throws
    func delete(id: String) async throws
}

enum ClientContainerError: Error {
    case notFound(id: String)
    case notRunning(id: String)
}

struct ClientContainerService: ClientContainerProtocol {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ClientContainer] {
        let allContainers = try await ClientContainer.list()
        var containers = allContainers
        if !showAll {
            containers = containers.filter { $0.status == .running }
        }
        for (key, values) in filters {
            switch key {
            case "status":
                containers = containers.filter { values.contains($0.status.rawValue) }
            case "exited":
                containers = containers.filter { container in
                    guard container.status == .stopped else { return false }
                    return values.contains("0") || values.isEmpty
                }
            case "label":
                containers = containers.filter { container in
                    let labels = container.configuration.labels
                    return values.allSatisfy { labelFilter in
                        guard let eqIdx = labelFilter.firstIndex(of: "=") else {
                            return labels.keys.contains(labelFilter)
                        }
                        let k = String(labelFilter.prefix(upTo: eqIdx))
                        let v = String(labelFilter.suffix(from: labelFilter.index(after: eqIdx)))
                        return labels[k] == v
                    }
                }
            case "name":
                containers = containers.filter { values.contains($0.id) }
            case "id":
                containers = containers.filter { values.contains($0.id) }
            case "ancestor":
                containers = containers.filter { values.contains($0.configuration.image.reference) }
            case "before":
                containers = containers.filter { container in
                    for beforeId in values {
                        if let beforeContainer = allContainers.first(where: { $0.id == beforeId || $0.id.hasPrefix(beforeId) }) {
                            return container.id < beforeContainer.id
                        }
                    }
                    return false
                }
            case "since":
                containers = containers.filter { container in
                    for sinceId in values {
                        if let sinceContainer = allContainers.first(where: { $0.id == sinceId || $0.id.hasPrefix(sinceId) }) {
                            return container.id > sinceContainer.id
                        }
                    }
                    return false
                }
            case "health":
                containers = containers.filter { container in
                    let healthStatus = container.status == .running ? "healthy" : "unhealthy"
                    return values.contains(healthStatus)
                }
            case "volume":
                containers = containers.filter { container in
                    values.contains("volume-filter-not-implemented")
                }
            case "expose":
                containers = containers.filter { container in
                    let exposedPorts = container.configuration.publishedPorts.map { "\($0.containerPort)/\($0.proto.rawValue)" }
                    return values.allSatisfy { port in
                        exposedPorts.contains { $0.contains(port) }
                    }
                }
            case "isolation":
                containers = containers.filter { container in
                    let isolation = container.configuration.platform.os == "linux" ? "process" : "hyperv"
                    return values.contains(isolation)
                }
            case "is-task":
                containers = containers.filter { container in
                    let isTask = container.configuration.labels["com.docker.swarm.task.id"] != nil
                    return values.contains(isTask ? "true" : "false")
                }
            case "network":
                containers = containers.filter { container in
                    let networkNames = container.networks.map { $0.network }
                    return values.allSatisfy { networkName in
                        networkNames.contains(networkName)
                    }
                }
            case "publish":
                containers = containers.filter { container in
                    let publishedPorts = container.configuration.publishedPorts.map { "\($0.hostPort):\($0.containerPort)" }
                    return values.allSatisfy { portMapping in
                        publishedPorts.contains { $0.contains(portMapping) }
                    }
                }
            default:
                continue
            }
        }
        return containers
    }

    func getContainer(id: String) async throws -> ClientContainer? {
        try await ClientContainer.get(id: id)
    }

    func enforceContainerRunning(container: ClientContainer) throws {
        guard container.status == .running else {
            throw ClientContainerError.notRunning(id: container.id)
        }
    }

    func start(id: String, detach: Bool = true) async throws {
        let container = try await ClientContainer.get(id: id)
        let stdin: FileHandle? = nil
        let stdout: FileHandle? = nil
        let stderr: FileHandle? = nil

        let stdio = [stdin, stdout, stderr]

        let process = try await container.bootstrap(stdio: stdio)
        try await process.start()
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
