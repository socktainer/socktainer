import ContainerClient
import Foundation

protocol ClientContainerProtocol: Sendable {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ClientContainer]
    func getContainer(id: String) async throws -> ClientContainer?
    func enforceContainerRunning(container: ClientContainer) throws

    func start(id: String, detach: Bool) async throws
    func stop(id: String) async throws
    func delete(id: String) async throws
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64)
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

    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        let allContainers = try await ClientContainer.list()

        var containersToDelete: [ClientContainer] = allContainers.filter { $0.status == .stopped }

        for (key, values) in filters {
            switch key {
            // NOTE: Currently this filter is useless, since Apple container doesn't
            //       store creation date for containers.
            case "until":
                containersToDelete = containersToDelete.filter { container in
                    for timestamp in values {
                        let dateFormatter = ISO8601DateFormatter()
                        if dateFormatter.date(from: timestamp) != nil {
                            return true
                        } else if let unixTimestamp = TimeInterval(timestamp) {
                            let date = Date(timeIntervalSince1970: unixTimestamp)
                            return Date() < date
                        }
                    }
                    return values.isEmpty
                }
            case "label":
                containersToDelete = containersToDelete.filter { container in
                    let labels = container.configuration.labels
                    return values.allSatisfy { labelFilter in
                        if labelFilter.contains("!=") {
                            if let eqIdx = labelFilter.range(of: "!=") {
                                let prefix = String(labelFilter.prefix(upTo: eqIdx.lowerBound))
                                let suffix = String(labelFilter.suffix(from: eqIdx.upperBound))
                                guard suffix.isEmpty else {
                                    return labels[prefix] != suffix
                                }
                                return !labels.keys.contains(prefix)
                            }
                            return false
                        } else if labelFilter.contains("=") {
                            if let eqIdx = labelFilter.firstIndex(of: "=") {
                                let k = String(labelFilter.prefix(upTo: eqIdx))
                                let v = String(labelFilter.suffix(from: labelFilter.index(after: eqIdx)))
                                return labels[k] == v
                            }
                            return false
                        } else {
                            return labels.keys.contains(labelFilter)
                        }
                    }
                }
            default:
                continue
            }
        }

        // NOTE: Apple container doesn't return the size of the container, only the
        //       image descriptor size (manifest) is logged.
        //       Perhaps we should fetch the image size ourselves.
        let spaceReclaimed: Int64 = 0

        var deletedIds: [String] = []

        for container in containersToDelete {
            do {
                try await container.delete()
                deletedIds.append(container.id)
            } catch {
                continue
            }
        }

        return (deletedContainers: deletedIds, spaceReclaimed: spaceReclaimed)
    }
}
