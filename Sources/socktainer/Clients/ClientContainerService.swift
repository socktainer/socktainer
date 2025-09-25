import ContainerClient
import Foundation

protocol ClientContainerProtocol: Sendable {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ClientContainer]
    func getContainer(id: String) async throws -> ClientContainer?
    func enforceContainerRunning(container: ClientContainer) throws

    func start(id: String, detachKeys: String?) async throws
    func stop(id: String, signal: String?, timeout: Int?) async throws
    func restart(id: String, signal: String?, timeout: Int?) async throws
    func kill(id: String, signal: String?) async throws
    func delete(id: String) async throws
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait
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

    func start(id: String, detachKeys: String?) async throws {
        guard let container = try await getContainer(id: id) else {
            throw ClientContainerError.notFound(id: id)
        }

        let stdin: FileHandle? = nil
        let stdout: FileHandle? = nil
        let stderr: FileHandle? = nil

        let stdio = [stdin, stdout, stderr]

        do {
            let process = try await container.bootstrap(stdio: stdio)
            try await process.start()
        } catch {
            // Check if the error indicates the container is already booted/bootstrapped
            let errorMessage = error.localizedDescription
            let isAlreadyBootstrapedError = errorMessage.contains("booted") || errorMessage.contains("expected to be in created state") || errorMessage.contains("invalidState")

            if isAlreadyBootstrapedError {
                return
            }

            throw error
        }
    }

    func stop(id: String, signal: String?, timeout: Int?) async throws {
        let container = try await ClientContainer.list().filter { $0.id == id }.first
        guard let container else {
            throw ClientContainerError.notFound(id: id)
        }

        let signal = try parseSignal(signal ?? "SIGTERM")

        let options = ContainerStopOptions(timeoutInSeconds: Int32(timeout ?? 5), signal: signal)
        try await container.stop(opts: options)
    }

    func kill(id: String, signal: String?) async throws {
        let container = try await ClientContainer.list().filter { $0.id == id }.first
        guard let container else {
            throw ClientContainerError.notFound(id: id)
        }

        guard container.status == .running else {
            throw ClientContainerError.notRunning(id: id)
        }

        let signal = try parseSignal(signal ?? "SIGKILL")

        try await container.kill(signal)
    }

    func restart(id: String, signal: String?, timeout: Int?) async throws {
        let container = try await ClientContainer.list().filter { $0.id == id }.first
        guard let container else {
            throw ClientContainerError.notFound(id: id)
        }

        if container.status == .running {
            try await stop(id: id, signal: signal, timeout: timeout)
        }

        try await start(id: id, detachKeys: nil)
    }

    func delete(id: String) async throws {
        let container = try await ClientContainer.list().filter { $0.id == id }.first
        guard let container else {
            throw ClientContainerError.notFound(id: id)
        }
        try await container.delete()
    }

    // NOTE: For Apple Container, we'll implement a simple polling mechanism
    //       since there's no direct wait API
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        var container = try await ClientContainer.list().filter { $0.id == id }.first
        guard let initialContainer = container else {
            throw ClientContainerError.notFound(id: id)
        }

        // For now, default to 0
        var exitCode: Int64 = 0

        switch condition {
        case .notRunning:
            while container?.status == .running {
                try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
                container = try await ClientContainer.list().first(where: { $0.id == id })
                guard let container = container else {
                    break
                }
            }

        case .nextExit:
            // Wait for next exit (only if currently running)
            if initialContainer.status == .running {
                while true {
                    try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
                    container = try await ClientContainer.list().first(where: { $0.id == id })
                    if container?.status != .running {
                        exitCode = 0
                        break
                    }
                }
            }

        case .removed:
            while try await ClientContainer.list().contains(where: { $0.id == id }) {
                try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
            }
        }

        return RESTContainerWait(statusCode: exitCode)
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
