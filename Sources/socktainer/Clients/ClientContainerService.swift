import ContainerAPIClient
import ContainerResource
import ContainerizationError
import Foundation

// Stores the exit code for each container's init process once it terminates.
// Both ClientContainerService.start() and the stdin-attach bootstrap path
// call process.wait() concurrently; whichever path runs will record the code
// here so ContainerWaitRoute can return the real exit status.
actor ContainerExitCodeStore {
    static let shared = ContainerExitCodeStore()

    private var codes: [String: Int32] = [:]

    func set(id: String, code: Int32) {
        codes[id] = code
    }

    func get(id: String) -> Int32? {
        codes[id]
    }

    func remove(id: String) {
        codes.removeValue(forKey: id)
    }
}

protocol ClientContainerProtocol: Sendable {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot]
    func getContainer(id: String) async throws -> ContainerSnapshot?
    func enforceContainerRunning(container: ContainerSnapshot) throws

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
    case ambiguousId(reference: String, matches: [String])
    case unsupportedCondition(ContainerWaitCondition)
}

struct ClientContainerService: ClientContainerProtocol {
    private let containerClient = ContainerClient()

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        let allContainers = try await containerClient.list()
        var containers = allContainers
        if !showAll {
            containers = containers.filter { $0.status == .running }
        }
        for (key, values) in filters {
            switch key {
            case "status":
                containers = containers.filter { values.contains($0.status.mobyState) }
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
                containers = containers.filter { container in
                    values.contains { value in
                        container.id == value || DockerContainerID.hexId(for: container).hasPrefix(value)
                    }
                }
            case "ancestor":
                containers = containers.filter { values.contains($0.configuration.image.reference) }
            case "before":
                containers = containers.filter { container in
                    for beforeId in values {
                        if let beforeContainer = allContainers.first(where: { $0.id == beforeId || $0.id.hasPrefix(beforeId) }) {
                            if let beforeTimestamp = AppleContainerTimestampResolver.containerCreationDate(beforeContainer),
                                let containerTimestamp = AppleContainerTimestampResolver.containerCreationDate(container)
                            {
                                return containerTimestamp < beforeTimestamp
                            }
                            return container.id < beforeContainer.id
                        }
                    }
                    return false
                }
            case "since":
                containers = containers.filter { container in
                    for sinceId in values {
                        if let sinceContainer = allContainers.first(where: { $0.id == sinceId || $0.id.hasPrefix(sinceId) }) {
                            if let sinceTimestamp = AppleContainerTimestampResolver.containerCreationDate(sinceContainer),
                                let containerTimestamp = AppleContainerTimestampResolver.containerCreationDate(container)
                            {
                                return containerTimestamp > sinceTimestamp
                            }
                            return container.id > sinceContainer.id
                        }
                    }
                    return false
                }
            case "health":
                // Health filtering requires the HealthCheckManager (available in
                // ContainerListRoute). The filter is applied there after this call
                // so we skip it here to avoid a stale heuristic.
                break
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

    func getContainer(id: String) async throws -> ContainerSnapshot? {
        let id = ContainerNameUtility.sanitize(id)
        do {
            return try await containerClient.get(id: id)
        } catch let error as ContainerizationError where error.code == .notFound {
            // The reference may be a Docker-shaped hex ID, or a truncated
            // prefix of one fed back from `docker ps` output; resolve it
            // against the derived IDs of all containers.
            let allContainers = try await containerClient.list()
            let entries = allContainers.map { (nativeId: $0.id, hexId: DockerContainerID.hexId(for: $0)) }
            switch DockerContainerID.resolve(reference: id, entries: entries) {
            case .match(let nativeId):
                return allContainers.first { $0.id == nativeId }
            case .ambiguous(let matches):
                throw ClientContainerError.ambiguousId(reference: id, matches: matches)
            case .none:
                return nil
            }
        }
    }

    func enforceContainerRunning(container: ContainerSnapshot) throws {
        guard container.status == .running else {
            throw ClientContainerError.notRunning(id: container.id)
        }
    }

    func start(id: String, detachKeys: String?) async throws {
        guard let container = try await getContainer(id: id) else {
            throw ClientContainerError.notFound(id: id)
        }

        if container.status == .running {
            return
        }

        let stdin: FileHandle? = nil
        let stdout: FileHandle? = nil
        let stderr: FileHandle? = nil

        let stdio = [stdin, stdout, stderr]

        do {
            let process = try await containerClient.bootstrap(id: container.id, stdio: stdio)
            // Clear any exit code recorded by a previous run of this container so
            // /wait blocks for the new init process rather than immediately
            // returning the stale code (e.g. after a restart).
            await ContainerExitCodeStore.shared.remove(id: container.id)
            try await process.start()
            // Wait for the init process in the background so we can capture its
            // real exit code without blocking the /start response.
            let containerId = container.id
            Task.detached {
                let code = (try? await process.wait()) ?? 0
                await ContainerExitCodeStore.shared.set(id: containerId, code: code)
            }
        } catch {
            // NOTE: If bootstrap fails because container is already booted,
            //       the attach handler may have already bootstrapped it
            let errorMessage = error.localizedDescription
            if errorMessage.contains("booted") || errorMessage.contains("expected to be in created state") {
                return
            }

            // Re-throw any other errors
            throw error
        }
    }

    func stop(id: String, signal: String?, timeout: Int?) async throws {
        let id = ContainerNameUtility.sanitize(id)
        guard let container = try await getContainer(id: id) else {
            throw ClientContainerError.notFound(id: id)
        }

        let signal = signal ?? "SIGTERM"

        let options = ContainerStopOptions(timeoutInSeconds: Int32(timeout ?? 5), signal: signal)
        try await containerClient.stop(id: container.id, opts: options)
    }

    func kill(id: String, signal: String?) async throws {
        let id = ContainerNameUtility.sanitize(id)
        guard let container = try await getContainer(id: id) else {
            throw ClientContainerError.notFound(id: id)
        }

        guard container.status == .running else {
            throw ClientContainerError.notRunning(id: id)
        }

        let signal = signal ?? "SIGKILL"

        try await containerClient.kill(id: container.id, signal: signal)
    }

    func restart(id: String, signal: String?, timeout: Int?) async throws {
        let id = ContainerNameUtility.sanitize(id)
        guard let container = try await getContainer(id: id) else {
            throw ClientContainerError.notFound(id: id)
        }

        if container.status == .running {
            try await stop(id: id, signal: signal, timeout: timeout)
        }

        try await start(id: id, detachKeys: nil)
    }

    func delete(id: String) async throws {
        let id = ContainerNameUtility.sanitize(id)
        guard let container = try await getContainer(id: id) else {
            throw ClientContainerError.notFound(id: id)
        }
        try await containerClient.delete(id: container.id)
    }

    // Poll until the container is no longer running, then return the real exit
    // code recorded by the background waiter started in start() (or by the
    // stdin-attach bootstrap path).
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        guard let container = try await getContainer(id: id) else {
            throw ClientContainerError.notFound(id: id)
        }
        // Poll by the native ID; the request reference may have been a hex ID
        // or a truncated prefix of one.
        let id = container.id

        // `docker run` issues /wait BEFORE /start, so the container is still in
        // `.created` state when we arrive here — we must NOT treat "not running"
        // as "exited". Instead poll until the init process actually finishes and
        // its real exit code is recorded by the background waiter in start().
        // The container persists for the duration of /wait (docker removes it
        // only after /wait returns), so disappearing means a race/out-of-band
        // removal and we fall back to the recorded code (or 0).
        switch condition {
        case .healthy:
            // ContainerWaitRoute intercepts condition=healthy and polls HealthCheckManager
            // directly — this branch in the service should never be reached in production.
            throw ClientContainerError.unsupportedCondition(.healthy)

        case .notRunning, .nextExit, .removed:
            // Wait until the init process exits and its code is recorded. For
            // `--rm` the container can be deleted the instant it exits (racing
            // the recorder), so also stop once it's gone, then grace-poll the
            // store below.
            while await ContainerExitCodeStore.shared.get(id: id) == nil {
                let current = try await containerClient.list().filter { $0.id == id }.first
                if current == nil {
                    var graceTries = 0
                    while await ContainerExitCodeStore.shared.get(id: id) == nil && graceTries < 30 {
                        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                        graceTries += 1
                    }
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            }

            // `removed` must block until the container is actually gone, not just
            // exited — otherwise the requested condition was never satisfied.
            if condition == .removed {
                while (try await containerClient.list().filter { $0.id == id }.first) != nil {
                    try await Task.sleep(nanoseconds: 200_000_000)  // 200ms
                }
            }
        }

        let code = await ContainerExitCodeStore.shared.get(id: id) ?? 0
        return RESTContainerWait(statusCode: Int64(code))
    }

    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        let allContainers = try await containerClient.list()

        var containersToDelete: [ContainerSnapshot] = allContainers.filter { $0.status == .stopped }

        for (key, values) in filters {
            switch key {
            case "until":
                containersToDelete = containersToDelete.filter { container in
                    guard let creationDate = AppleContainerTimestampResolver.containerCreationDate(container) else {
                        // If label is not present or invalid, don't prune
                        return false
                    }

                    for timestamp in values {
                        let untilDate: Date?
                        let dateFormatter = ISO8601DateFormatter()
                        if let date = dateFormatter.date(from: timestamp) {
                            untilDate = date
                        } else if let unixTimestamp = TimeInterval(timestamp) {
                            untilDate = Date(timeIntervalSince1970: unixTimestamp)
                        } else {
                            untilDate = nil
                        }

                        if let untilDate = untilDate {
                            if creationDate < untilDate {
                                return true  // Prune if created before the 'until' timestamp
                            }
                        }
                    }
                    return false
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
                try await containerClient.delete(id: container.id)
                deletedIds.append(container.id)
            } catch {
                continue
            }
        }

        return (deletedContainers: deletedIds, spaceReclaimed: spaceReclaimed)
    }
}
