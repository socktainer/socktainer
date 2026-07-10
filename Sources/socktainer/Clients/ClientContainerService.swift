import ContainerAPIClient
import ContainerResource
import ContainerizationError
import Foundation
import Logging

// Stores the exit code for each container's init process once it terminates.
// Both ClientContainerService.start() and the stdin-attach bootstrap path
// call process.wait() concurrently; whichever path runs will record the code
// here so ContainerWaitRoute can return the real exit status.
actor ContainerExitCodeStore {
    static let shared = ContainerExitCodeStore()

    private var codes: [String: Int32] = [:]
    private var waiters: [String: [CheckedContinuation<Int32, Never>]] = [:]

    func set(id: String, code: Int32) {
        codes[id] = code
        // Resume anyone awaiting this container's exit code (e.g. the die-event observer),
        // delivering the authoritative recorded value rather than a timed-poll fallback.
        if let pending = waiters.removeValue(forKey: id) {
            for continuation in pending { continuation.resume(returning: code) }
        }
    }

    func get(id: String) -> Int32? {
        codes[id]
    }

    func remove(id: String) {
        codes.removeValue(forKey: id)
    }

    /// Suspends until the exit code for `id` is recorded, returning the exact recorded value.
    /// If a code is already present it returns immediately. This avoids the grace-poll/`?? 0`
    /// race that `wait(condition:)` is subject to under load — the recorder calls `set(id:)`
    /// with the real code once the init process exits, which resumes the waiter deterministically.
    func waitForCode(id: String) async -> Int32 {
        if let code = codes[id] { return code }
        return await withCheckedContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
    }

    /// Sentinel recorded when the init process's exit code could not be obtained after retries.
    /// Distinguishes "wait failed" from a genuine exit code of 0.
    static let waitFailureSentinel: Int32 = -1

    /// Resolves a process's exit code with bounded retry before it is recorded.
    ///
    /// `ClientProcess.wait()` is an XPC round-trip to the Apple Container daemon; under
    /// concurrent load (many containers exiting at once) that round-trip can throw a transient
    /// connection error. The previous recorder collapsed any such throw into `?? 0`, recording
    /// a fake exit code of 0 that then surfaced in the container `die` event (issue #90:
    /// expected 7, observed 0). Retrying the wait yields the authoritative code; a process that
    /// has already exited answers the re-issued wait immediately. After `maxAttempts` failures we
    /// record `waitFailureSentinel` so observers can tell a failed wait from a real exit-0.
    static func resolveExitCode(
        maxAttempts: Int = 5,
        retryDelayNs: UInt64 = 100_000_000,
        logger: Logger? = nil,
        wait: () async throws -> Int32
    ) async -> Int32 {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await wait()
            } catch {
                logger?.warning("exit-code wait() threw on attempt \(attempt)/\(maxAttempts): \(error)")
                if attempt >= maxAttempts { return waitFailureSentinel }
                if retryDelayNs > 0 { try? await Task.sleep(nanoseconds: retryDelayNs) }
            }
        }
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
        let allContainers = Self.withoutDNSSidecars(try await containerClient.list())
        let running = showAll ? allContainers : allContainers.filter { $0.status == .running }
        return Self.applyFilters(running, filters: filters, allContainers: allContainers)
    }

    static func withoutDNSSidecars(_ snapshots: [ContainerSnapshot]) -> [ContainerSnapshot] {
        snapshots.filter { !isDNSSidecar($0) }
    }

    static func isDNSSidecar(_ snapshot: ContainerSnapshot) -> Bool {
        snapshot.configuration.labels[NetworkDNSManager.roleLabel] == NetworkDNSManager.dnsRole
    }

    /// Applies parsed Docker container filters to a snapshot list.
    /// `allContainers` is the unfiltered set used by `before`/`since` for
    /// relative ordering; defaults to `containers` when not available.
    static func applyFilters(
        _ containers: [ContainerSnapshot],
        filters: [String: [String]],
        allContainers: [ContainerSnapshot] = []
    ) -> [ContainerSnapshot] {
        let referencePool = allContainers.isEmpty ? containers : allContainers
        var result = containers
        for (key, values) in filters {
            switch key {
            case "status":
                result = result.filter { values.contains($0.status.mobyState) }
            case "exited":
                result = result.filter { container in
                    guard container.status == .stopped else { return false }
                    return values.contains("0") || values.isEmpty
                }
            case "label":
                result = result.filter { container in
                    let labels = container.configuration.labels
                    return values.allSatisfy { labelFilter in
                        guard let eqIdx = labelFilter.firstIndex(of: "=") else {
                            return LabelNormalization.filterContainsKey(labelFilter, in: labels)
                        }
                        let k = String(labelFilter.prefix(upTo: eqIdx))
                        let v = String(labelFilter.suffix(from: labelFilter.index(after: eqIdx)))
                        return LabelNormalization.filterValue(in: labels, forKey: k) == v
                    }
                }
            case "name":
                result = result.filter { values.contains($0.id) }
            case "id":
                result = result.filter { container in
                    values.contains { value in
                        container.id == value || DockerContainerID.hexId(for: container).hasPrefix(value)
                    }
                }
            case "ancestor":
                result = result.filter { values.contains($0.configuration.image.reference) }
            case "before":
                result = result.filter { container in
                    for beforeId in values {
                        if let beforeContainer = referencePool.first(where: {
                            $0.id == beforeId || $0.id.hasPrefix(beforeId)
                                || DockerContainerID.hexId(for: $0).hasPrefix(beforeId)
                        }) {
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
                result = result.filter { container in
                    for sinceId in values {
                        if let sinceContainer = referencePool.first(where: {
                            $0.id == sinceId || $0.id.hasPrefix(sinceId)
                                || DockerContainerID.hexId(for: $0).hasPrefix(sinceId)
                        }) {
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
                result = result.filter { _ in false }
            case "expose":
                result = result.filter { container in
                    let exposedPorts = container.configuration.publishedPorts.map { "\($0.containerPort)/\($0.proto.rawValue)" }
                    return values.allSatisfy { port in exposedPorts.contains { $0.contains(port) } }
                }
            case "isolation":
                result = result.filter { container in
                    let isolation = container.configuration.platform.os == "linux" ? "process" : "hyperv"
                    return values.contains(isolation)
                }
            case "is-task":
                result = result.filter { container in
                    let isTask = container.configuration.labels["com.docker.swarm.task.id"] != nil
                    return values.contains(isTask ? "true" : "false")
                }
            case "network":
                result = result.filter { container in
                    let networkNames = container.networks.map { $0.network }
                    return values.allSatisfy { networkNames.contains($0) }
                }
            case "publish":
                result = result.filter { container in
                    let publishedPorts = container.configuration.publishedPorts.map { "\($0.hostPort):\($0.containerPort)" }
                    return values.allSatisfy { portMapping in publishedPorts.contains { $0.contains(portMapping) } }
                }
            default:
                continue
            }
        }
        return result
    }

    func getContainer(id: String) async throws -> ContainerSnapshot? {
        let id = ContainerNameUtility.sanitize(id)
        do {
            let snapshot = try await containerClient.get(id: id)
            return Self.isDNSSidecar(snapshot) ? nil : snapshot
        } catch let error as ContainerizationError where error.code == .notFound {
            // The reference may be a Docker-shaped hex ID, or a truncated
            // prefix of one fed back from `docker ps` output; resolve it
            // against the derived IDs of all containers.
            let allContainers = Self.withoutDNSSidecars(try await containerClient.list())
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

    // Apple Container's Virtualization.framework has been observed to fail to service
    // virtio-net queues promptly (guest kernel NETDEV WATCHDOG timeouts cascading into
    // DNS/connect failures, and in the worst case a guest kernel panic) when many VMs boot
    // or tear down at once — e.g. `docker compose up`/`down` firing many concurrent
    // create+start or stop calls. start/stop/restart all hold a VMLifecycleAdmission slot for
    // their full VM-transition duration; excess calls queue rather than piling onto the storm.

    func start(id: String, detachKeys: String?) async throws {
        guard let container = try await getContainer(id: id) else {
            throw ClientContainerError.notFound(id: id)
        }

        if container.status == .running {
            return
        }

        try await VMLifecycleAdmission.shared.withSlot {
            try await self.startInternal(container: container)
        }
    }

    private func startInternal(container: ContainerSnapshot) async throws {
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
            let exitLogger = Logger(label: "socktainer.exitcode")
            Task.detached {
                let code = await ContainerExitCodeStore.resolveExitCode(logger: exitLogger) {
                    try await process.wait()
                }
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

        // Mark before issuing the request: a stop that throws because the VM already died
        // on its own should still suppress restart-policy auto-restart for that exit.
        await ContainerRestartState.shared.markExplicitlyStopped(id: container.id)
        try await VMLifecycleAdmission.shared.withSlot {
            try await self.stopInternal(container: container, signal: signal, timeout: timeout)
        }
    }

    private func stopInternal(container: ContainerSnapshot, signal: String?, timeout: Int?) async throws {
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

        await ContainerRestartState.shared.markExplicitlyStopped(id: container.id)
        try await containerClient.kill(id: container.id, signal: signal)
    }

    func restart(id: String, signal: String?, timeout: Int?) async throws {
        let id = ContainerNameUtility.sanitize(id)
        guard let container = try await getContainer(id: id) else {
            throw ClientContainerError.notFound(id: id)
        }

        let wasRunning = container.status == .running
        if wasRunning {
            await ContainerRestartState.shared.markExplicitlyStopped(id: container.id)
        }

        // Hold a single slot across stop+start: acquiring separately would let other queued
        // work run in between, leaving the container stopped longer than necessary.
        try await VMLifecycleAdmission.shared.withSlot {
            if wasRunning {
                try await self.stopInternal(container: container, signal: signal, timeout: timeout)
            }
            try await self.startInternal(container: container)
        }
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
        let allContainers = Self.withoutDNSSidecars(try await containerClient.list())

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
                                let key = String(labelFilter.prefix(upTo: eqIdx.lowerBound))
                                let suffix = String(labelFilter.suffix(from: eqIdx.upperBound))
                                guard suffix.isEmpty else {
                                    return LabelNormalization.filterValue(in: labels, forKey: key) != suffix
                                }
                                return !LabelNormalization.filterContainsKey(key, in: labels)
                            }
                            return false
                        } else if labelFilter.contains("=") {
                            if let eqIdx = labelFilter.firstIndex(of: "=") {
                                let k = String(labelFilter.prefix(upTo: eqIdx))
                                let v = String(labelFilter.suffix(from: labelFilter.index(after: eqIdx)))
                                return LabelNormalization.filterValue(in: labels, forKey: k) == v
                            }
                            return false
                        } else {
                            return LabelNormalization.filterContainsKey(labelFilter, in: labels)
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
