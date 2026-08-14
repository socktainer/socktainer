import Foundation
import Vapor

private final class GuestStreamCollector: @unchecked Sendable {
    private static let maximumBytes = 16 * 1024 * 1024
    private let lock = NSLock()
    private let collectStdout: Bool
    private let collectStderr: Bool
    private var stdout = Data()
    private var stderr = Data()
    private var overflowed = false

    init(stdout: Bool, stderr: Bool) {
        self.collectStdout = stdout
        self.collectStderr = stderr
    }

    func append(_ frame: GuestFrame) {
        guard let data = frame.data else { return }
        lock.lock()
        defer { lock.unlock() }
        guard stdout.count + stderr.count + data.count <= Self.maximumBytes else {
            overflowed = true
            return
        }
        switch frame.stream {
        case .stdout where collectStdout: stdout.append(data)
        case .stderr where collectStderr: stderr.append(data)
        case .stdout, .stderr: break
        case nil: break
        }
    }

    func output(exitCode: Int32) throws -> DockerRuntimeProcessOutput {
        lock.lock()
        defer { lock.unlock() }
        if overflowed {
            throw DockerRuntimeRouteError.invalidRequest(
                "exec output exceeded the 16 MiB buffered-output limit"
            )
        }
        return DockerRuntimeProcessOutput(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }
}

private final class GuestStreamRequestControl: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) { lock.withLock { self.task = task } }
    func cancel() { lock.withLock { task?.cancel() } }
}

private struct GuestContainerPayload: Decodable {
    let container: GuestContainer
}

private struct GuestContainerListPayload: Decodable {
    let containers: [GuestContainer]
}

private struct GuestContainer: Decodable {
    let id: String
    let image: String
    let status: String
    let exitCode: UInt32?
    let createdAt: Date
    let publishedPorts: [GuestPublishedPort]?
    let metadata: GuestContainerMetadata?
}

private struct GuestContainerMetadata: Decodable {
    let name: String?
    let args: [String]?
    let labels: [String: String]?
    let terminal: Bool?
    let autoRemove: Bool?
    let portBindings: [DockerRuntimePortBinding]?
    let publishedPorts: [GuestPublishedPort]?
}

private struct GuestPublishedPort: Decodable {
    let containerPort: Int
    let guestPort: Int
    let `protocol`: String?
}

private struct GuestImagePayload: Decodable {
    let name: String
    let digest: String
}

private struct GuestImageDetailPayload: Decodable {
    let id: String
    let digest: String
    let references: [String]
    let createdAt: Date
    let size: Int64
    let labels: [String: String]?
    let rootFSLayers: [String]?
}

private struct GuestImageListPayload: Decodable {
    let images: [GuestImageDetailPayload]
}

private struct GuestImageDeletePayload: Decodable {
    let deleted: [String]?
    let untagged: [String]?
    let reclaimed: Int64?
}

private struct GuestExitPayload: Decodable {
    let id: String
    let exitCode: UInt32
}

private struct GuestLogsPayload: Decodable {
    let stdout: Data?
    let stderr: Data?
}

protocol GuestRuntimeEventConnecting: Sendable {
    func connect() async throws -> AsyncStream<GuestFrame>
}

actor PersistentEngineGuestRuntimeEventConnector: GuestRuntimeEventConnecting {
    private let engine: PersistentEngine

    init(engine: PersistentEngine) {
        self.engine = engine
    }

    func connect() async throws -> AsyncStream<GuestFrame> {
        let connection = try await engine.readyConnection()
        return await connection.events()
    }
}

actor GuestRuntimeEventMonitor {
    typealias Handler = @Sendable (GuestFrame) async -> Void
    typealias ReconnectHandler = @Sendable () async -> Void

    private let connector: any GuestRuntimeEventConnecting
    private let handler: Handler
    private let onReconnect: ReconnectHandler
    private var task: Task<Void, Never>?

    init(
        connector: any GuestRuntimeEventConnecting,
        handler: @escaping Handler,
        onReconnect: @escaping ReconnectHandler = {}
    ) {
        self.connector = connector
        self.handler = handler
        self.onReconnect = onReconnect
    }

    func start() async throws {
        guard task == nil else { return }
        let initialEvents = try await connector.connect()
        task = Task { [weak self] in
            await self?.monitor(initialEvents)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func monitor(_ initialEvents: AsyncStream<GuestFrame>) async {
        var stream = initialEvents
        while !Task.isCancelled {
            for await event in stream {
                await handler(event)
            }
            guard !Task.isCancelled else { return }
            do {
                stream = try await connector.connect()
                await onReconnect()
            } catch {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

struct GuestExitCodeIndex: Sendable {
    static let maximumEntries = 4_096

    private var codes: [String: Int32] = [:]
    private var order: [String] = []

    mutating func record(id: String, code: Int32) {
        if codes.updateValue(code, forKey: id) == nil {
            order.append(id)
        }
        while order.count > Self.maximumEntries {
            codes.removeValue(forKey: order.removeFirst())
        }
    }

    func code(for id: String) -> Int32? { codes[id] }

    mutating func remove(id: String) {
        codes.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    func recoverNotFound(id: String, error: DockerRuntimeRouteError) throws -> Int32 {
        guard case .notFound = error, let code = code(for: id) else { throw error }
        return code
    }
}

actor GuestWaitSingleFlight {
    private struct Entry {
        let token: UUID
        let task: Task<Int32, Error>
    }

    private var pending: [String: Entry] = [:]

    func run(
        id: String, operation: @escaping @Sendable () async throws -> Int32
    ) async throws -> Int32 {
        if let entry = pending[id] { return try await entry.task.value }
        let token = UUID()
        let task = Task { try await operation() }
        pending[id] = Entry(token: token, task: task)
        do {
            let result = try await task.value
            finish(id: id, token: token)
            return result
        } catch {
            finish(id: id, token: token)
            throw error
        }
    }

    private func finish(id: String, token: UUID) {
        guard pending[id]?.token == token else { return }
        pending.removeValue(forKey: id)
    }
}

actor GuestStartGate {
    private var waiters: [String: [UUID: CheckedContinuation<Void, Error>]] = [:]
    private var openTokens: Set<UUID> = []

    func wait(id: String) async throws {
        let token = UUID()
        openTokens.insert(token)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id, default: [:]][token] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id: id, token: token) }
        }
    }

    func finish(id: String, result: Result<Void, Error>) {
        let entries = waiters.removeValue(forKey: id) ?? [:]
        for (token, continuation) in entries {
            openTokens.remove(token)
            continuation.resume(with: result)
        }
    }

    func waiterCount(id: String) -> Int { waiters[id]?.count ?? 0 }

    private func cancel(id: String, token: UUID) {
        guard openTokens.remove(token) != nil,
            let continuation = waiters[id]?.removeValue(forKey: token)
        else { return }
        if waiters[id]?.isEmpty == true { waiters.removeValue(forKey: id) }
        continuation.resume(throwing: CancellationError())
    }
}

actor GuestRemovalGate {
    private static let maximumCompletedEntries = 4_096

    private var waiters: [String: [UUID: CheckedContinuation<Int32, Error>]] = [:]
    private var openTokens: Set<UUID> = []
    private var completed: [String: Int32] = [:]
    private var completedOrder: [String] = []

    func wait(id: String) async throws -> Int32 {
        if let exitCode = completed[id] { return exitCode }
        let token = UUID()
        openTokens.insert(token)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id, default: [:]][token] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id: id, token: token) }
        }
    }

    func signal(id: String, exitCode: Int32) {
        if completed[id] == nil {
            completedOrder.append(id)
        }
        completed[id] = exitCode
        while completedOrder.count > Self.maximumCompletedEntries {
            completed.removeValue(forKey: completedOrder.removeFirst())
        }
        let entries = waiters.removeValue(forKey: id) ?? [:]
        for (token, continuation) in entries {
            openTokens.remove(token)
            continuation.resume(returning: exitCode)
        }
    }

    func waiterCount(id: String) -> Int { waiters[id]?.count ?? 0 }

    private func cancel(id: String, token: UUID) {
        guard openTokens.remove(token) != nil,
            let continuation = waiters[id]?.removeValue(forKey: token)
        else { return }
        if waiters[id]?.isEmpty == true { waiters.removeValue(forKey: id) }
        continuation.resume(throwing: CancellationError())
    }
}

/// Maps Docker operations to the one multiplexed guest connection. The host
/// keeps Docker-only metadata; containerd remains the authority for processes,
/// snapshots, and lifecycle state.
actor GuestRuntime: DockerRuntimeRouteBackend {
    private struct Metadata: Sendable {
        let name: String
        let command: [String]
        let labels: [String: String]
        let tty: Bool
        let autoRemove: Bool
        let image: String
        let createdAt: Date
        var ports: [DockerRuntimePortBinding]
        var guestPorts: [Int]
        var state: EngineContainerState
        var exitCode: Int32?
    }

    private let engine: PersistentEngine
    private let portPublisher: GuestPortPublicationManager
    private let broadcaster: EventBroadcaster?
    private var metadata: [String: Metadata] = [:]
    private var execs: [String: DockerRuntimeExecCreate] = [:]
    private var starting: Set<String> = []
    private let starts = GuestStartGate()
    private var pendingPublications: Set<String> = []
    private var eventMonitor: GuestRuntimeEventMonitor?
    private var reservedGuestPorts: Set<Int> = []
    private var exitCodes = GuestExitCodeIndex()
    private let waits = GuestWaitSingleFlight()
    private let removals = GuestRemovalGate()

    init(
        engine: PersistentEngine,
        portPublisher: GuestPortPublicationManager,
        broadcaster: EventBroadcaster? = nil
    ) {
        self.engine = engine
        self.portPublisher = portPublisher
        self.broadcaster = broadcaster
    }

    func startEventMonitor() async throws {
        guard eventMonitor == nil else { return }
        try await restoreRuntimeState()
        let monitor = GuestRuntimeEventMonitor(
            connector: PersistentEngineGuestRuntimeEventConnector(engine: engine)
        ) { [weak self] event in
            await self?.handle(event: event)
        } onReconnect: { [weak self] in
            try? await self?.restoreRuntimeState()
        }
        try await monitor.start()
        eventMonitor = monitor
        try await restoreRuntimeState()
    }

    func stopEventMonitor() async {
        await eventMonitor?.stop()
        eventMonitor = nil
    }

    func pullImage(
        reference: String, platform: String?, auth: DockerRegistryAuth?
    ) async throws -> DockerRuntimeImage {
        let guestReference = Self.normalizedRegistryReference(reference)
        var requestPayload: [String: JSONValue] = [
            "reference": .string(guestReference), "snapshotter": .string("overlayfs"),
        ]
        if let platform, !platform.isEmpty { requestPayload["platform"] = .string(platform) }
        if let username = auth?.username, !username.isEmpty {
            requestPayload["username"] = .string(username)
            if let secret = auth?.password ?? auth?.identitytoken, !secret.isEmpty {
                requestPayload["secret"] = .string(secret)
            }
        }
        let response = try await request("image.pull", requestPayload)
        let payload: GuestImagePayload = try decode(response)
        await broadcaster?.broadcast(
            DockerEvent.make(
                type: "image", action: "pull", actorID: payload.digest,
                attributes: ["name": payload.name]
            )
        )
        return DockerRuntimeImage(reference: payload.name, digest: payload.digest)
    }

    func listImages() async throws -> [DockerRuntimeImage] {
        let payload: GuestImageListPayload = try decode(try await request("image.list", [:]))
        return payload.images.map(Self.dockerImage)
    }

    func inspectImage(reference: String) async throws -> DockerRuntimeImage {
        let response = try await request(
            "image.inspect", ["reference": .string(Self.normalizedRegistryReference(reference))]
        )
        return Self.dockerImage(try decode(response, as: GuestImageDetailPayload.self))
    }

    func deleteImage(reference: String, force: Bool) async throws -> DockerRuntimeImageDelete {
        let response = try await request(
            "image.delete",
            ["reference": .string(Self.normalizedRegistryReference(reference)), "force": .bool(force)]
        )
        return Self.dockerImageDelete(try decode(response, as: GuestImageDeletePayload.self))
    }

    func pruneImages(all: Bool) async throws -> DockerRuntimeImageDelete {
        let response = try await request("image.prune", ["all": .bool(all)])
        return Self.dockerImageDelete(try decode(response, as: GuestImageDeletePayload.self))
    }

    func tagImage(source: String, target: String) async throws {
        _ = try await request(
            "image.tag",
            [
                "source": .string(Self.normalizedRegistryReference(source)),
                "target": .string(Self.normalizedRegistryReference(target)),
            ]
        )
    }

    func createContainer(_ request: DockerRuntimeContainerCreate) async throws -> DockerRuntimeContainer {
        let id = Self.makeID()
        let containerName = request.name.map(Self.normalizedContainerName) ?? id
        if let name = request.name, !name.isEmpty {
            try ensureNameAvailable(name)
        }
        guard
            let allocatedGuestPorts = Self.lowestAvailableGuestPorts(
                count: request.ports.count,
                range: PublishedPortProxyRange.ports,
                excluding: reservedGuestPorts
            )
        else {
            throw DockerRuntimeRouteError.conflict("published guest port range is exhausted")
        }
        reservedGuestPorts.formUnion(allocatedGuestPorts)
        var committedReservation = false
        defer {
            if !committedReservation {
                reservedGuestPorts.subtract(allocatedGuestPorts)
            }
        }
        let hostSource = try await vmnetHostSource(required: !request.ports.isEmpty)
        let requestedPorts = zip(request.ports, allocatedGuestPorts).map { port, guestPort in
            JSONValue.object([
                "containerPort": .number(Double(port.containerPort)),
                "guestPort": .number(Double(guestPort)),
                "protocol": .string(port.proto),
                "hostSource": .string(hostSource),
            ])
        }
        var payload: [String: JSONValue] = [
            "id": .string(id),
            "image": .string(Self.normalizedRegistryReference(request.image)),
            "args": .array(request.command.map(JSONValue.string)),
            "env": .array(request.environment.map(JSONValue.string)),
            "labels": .object(request.labels.mapValues(JSONValue.string)),
            "hostname": request.hostname.map(JSONValue.string) ?? .string(id.prefix(12).description),
            "readonlyRootfs": .bool(false),
            "autoRemove": .bool(request.autoRemove),
            "snapshotter": .string("overlayfs"),
            "runtime": .string("io.containerd.runc.v2"),
            "runtimeBinary": .string("/usr/bin/runc"),
            "network": .object(["mode": .string("private")]),
            "publishedPorts": .array(requestedPorts),
            "mounts": .array(
                request.mounts.map {
                    .object([
                        "source": .string($0.source), "target": .string($0.target),
                        "type": .string("bind"), "readonly": .bool($0.readOnly),
                    ])
                }
            ),
            "metadata": .object([
                "name": .string(containerName),
                "args": .array(request.command.map(JSONValue.string)),
                "labels": .object(request.labels.mapValues(JSONValue.string)),
                "terminal": .bool(request.tty),
                "autoRemove": .bool(request.autoRemove),
                "portBindings": .array(request.ports.map(Self.portBindingJSON)),
            ]),
        ]
        if let entrypoint = request.entrypoint {
            payload["entrypoint"] = .array(entrypoint.map(JSONValue.string))
        }
        if let cmd = request.cmd {
            payload["cmd"] = .array(cmd.map(JSONValue.string))
        }
        if let cwd = request.workingDirectory, !cwd.isEmpty { payload["cwd"] = .string(cwd) }
        if let user = request.user, !user.isEmpty { payload["user"] = .string(user) }
        let response = try await self.request("container.create", payload)
        let guest: GuestContainerPayload = try decode(response)
        metadata[id] = Metadata(
            name: containerName,
            command: request.command,
            labels: request.labels,
            tty: request.tty,
            autoRemove: request.autoRemove,
            image: guest.container.image,
            createdAt: guest.container.createdAt,
            ports: request.ports,
            guestPorts: allocatedGuestPorts,
            state: .created,
            exitCode: nil
        )
        committedReservation = true
        await broadcastContainer("create", id: id)
        return dockerContainer(guest.container)
    }

    static func lowestAvailableGuestPorts(
        count: Int,
        range: ClosedRange<Int>,
        excluding reserved: Set<Int>
    ) -> [Int]? {
        guard count >= 0 else { return nil }
        let available = range.lazy.filter { !reserved.contains($0) }.prefix(count)
        guard available.count == count else { return nil }
        return Array(available)
    }

    func startContainer(id: String) async throws {
        let resolved = try await resolve(id)
        if starting.contains(resolved) {
            try await starts.wait(id: resolved)
            return
        }
        starting.insert(resolved)
        defer { starting.remove(resolved) }
        let meta = metadata[resolved]
        if let state = meta?.state, !Self.requiresStart(state) {
            guard
                Self.requiresPortPublicationRetry(
                    state: state, publicationPending: pendingPublications.contains(resolved)
                ), let meta
            else { return }
            do {
                try await publishPorts(id: resolved, metadata: meta, guestPorts: meta.guestPorts)
            } catch {
                await starts.finish(id: resolved, result: .failure(error))
                throw error
            }
            await starts.finish(id: resolved, result: .success(()))
            return
        }
        let hostSource = try await vmnetHostSource(required: meta?.ports.isEmpty == false)
        let confirmedPorts = zip(meta?.ports ?? [], meta?.guestPorts ?? []).map { binding, guestPort in
            JSONValue.object([
                "containerPort": .number(Double(binding.containerPort)),
                "guestPort": .number(Double(guestPort)),
                "protocol": .string(binding.proto),
                "hostSource": .string(hostSource),
            ])
        }
        do {
            exitCodes.remove(id: resolved)
            metadata[resolved]?.state = .created
            metadata[resolved]?.exitCode = nil
            let response = try await request(
                "container.start",
                ["id": .string(resolved), "publishedPorts": .array(confirmedPorts)]
            )
            let started = try decode(response, as: GuestContainerPayload.self).container
            if metadata[resolved]?.state != .exited {
                metadata[resolved]?.state = .running
            }
            if let meta, !meta.ports.isEmpty, metadata[resolved]?.state == .running {
                pendingPublications.insert(resolved)
                try await publishPorts(
                    id: resolved,
                    metadata: meta,
                    guestPorts: started.publishedPorts?.map(\.guestPort) ?? meta.guestPorts
                )
            }
        } catch {
            await starts.finish(id: resolved, result: .failure(error))
            throw error
        }
        await starts.finish(id: resolved, result: .success(()))
        await broadcastContainer("start", id: resolved)
    }

    static func requiresPortPublicationRetry(
        state: EngineContainerState, publicationPending: Bool
    ) -> Bool {
        state == .running && publicationPending
    }

    private func publishPorts(id: String, metadata: Metadata, guestPorts: [Int]) async throws {
        let published = try await portPublisher.publish(
            containerID: id,
            bindings: metadata.ports,
            guestPorts: guestPorts
        )
        self.metadata[id]?.ports = published
        pendingPublications.remove(id)
        do {
            try await persistPortBindings(containerID: id, bindings: published)
        } catch {
            try await portPublisher.remove(containerID: id)
            pendingPublications.insert(id)
            throw error
        }
    }

    func killContainer(id: String, signal: UInt32) async throws {
        let resolved = try await resolve(id)
        _ = try await request(
            "container.kill", ["id": .string(resolved), "signal": .number(Double(signal))]
        )
        await broadcastContainer(
            "kill", id: resolved, extra: ["signal": String(signal)]
        )
    }

    func waitContainer(id: String, condition: ContainerWaitCondition) async throws -> Int32 {
        guard condition != .healthy else {
            throw DockerRuntimeRouteError.invalidRequest("healthy wait is not supported")
        }
        if condition != .removed, let code = exitCodes.code(for: id) { return code }
        let resolved: String
        do {
            resolved = try await resolve(id)
        } catch let error as DockerRuntimeRouteError {
            guard condition != .removed else { throw error }
            return try exitCodes.recoverNotFound(id: id, error: error)
        }
        if condition == .removed {
            return try await removals.wait(id: resolved)
        }
        if condition != .removed, let code = exitCodes.code(for: resolved) { return code }
        if metadata[resolved]?.state == .created {
            try await starts.wait(id: resolved)
        }
        let exitCode = try await waits.run(id: resolved) { [self] in
            try await performGuestWait(id: resolved)
        }
        if metadata[resolved]?.autoRemove == true {
            try await portPublisher.remove(containerID: resolved)
        }
        return exitCode
    }

    private func performGuestWait(id: String) async throws -> Int32 {
        let response: GuestFrame
        do {
            response = try await request("container.wait", ["id": .string(id)])
        } catch let error as DockerRuntimeRouteError {
            return try exitCodes.recoverNotFound(id: id, error: error)
        }
        let exitCode: Int32
        if let code = response.exitCode {
            exitCode = code
        } else {
            exitCode = Int32(try decode(response, as: GuestExitPayload.self).exitCode)
        }
        // The guest wait response is sent after its log copier drains. Publish
        // the result before the single-flight task completes and is removed.
        exitCodes.record(id: id, code: exitCode)
        metadata[id]?.state = .exited
        metadata[id]?.exitCode = exitCode
        return exitCode
    }

    func containerAutoRemove(id: String) async throws -> Bool {
        let resolved = try await resolve(id)
        return metadata[resolved]?.autoRemove == true
    }

    func deleteContainer(id: String, force: Bool, removeVolumes: Bool) async throws {
        let resolved = try await resolve(id)
        let hasPublishedPorts = metadata[resolved]?.ports.isEmpty == false
        let exitCode = metadata[resolved]?.exitCode ?? exitCodes.code(for: resolved) ?? 0
        _ = try await request(
            "container.delete",
            ["id": .string(resolved), "force": .bool(force), "snapshot": .bool(true)]
        )
        await starts.finish(
            id: resolved,
            result: .failure(DockerRuntimeRouteError.notFound("container \(resolved)"))
        )
        if hasPublishedPorts {
            try await portPublisher.remove(containerID: resolved)
        }
        releaseGuestPorts(containerID: resolved)
        pendingPublications.remove(resolved)
        metadata.removeValue(forKey: resolved)
        await removals.signal(id: resolved, exitCode: exitCode)
        await broadcaster?.broadcast(
            DockerEvent.simpleEvent(
                id: resolved, type: "container", status: "destroy",
                image: "", name: resolved
            )
        )
    }

    func inspectContainer(id: String) async throws -> DockerRuntimeContainer {
        let resolved = try await resolve(id)
        let response = try await request("container.inspect", ["id": .string(resolved)])
        return dockerContainer(try decode(response, as: GuestContainerPayload.self).container)
    }

    static func requiresStart(_ state: EngineContainerState) -> Bool {
        state != .running
    }

    func listContainers(showAll: Bool) async throws -> [DockerRuntimeContainer] {
        let response = try await request("container.list", [:])
        let payload: GuestContainerListPayload = try decode(response)
        return payload.containers.compactMap { container in
            guard showAll || container.status == "running" else { return nil }
            return dockerContainer(container)
        }
    }

    func createExec(_ request: DockerRuntimeExecCreate) async throws -> String {
        _ = try await resolve(request.containerID)
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        execs[id] = request
        return id
    }

    private func ensureNameAvailable(_ requestedName: String) throws {
        let normalized = Self.normalizedContainerName(requestedName)
        if let existing = metadata.first(where: { $0.value.name == normalized }) {
            throw DockerRuntimeRouteError.conflict(
                "Conflict. The container name /\(normalized) is already in use by container \(existing.key)."
            )
        }
    }

    func startExec(id: String, detach: Bool, tty: Bool) async throws -> DockerRuntimeProcessOutput {
        guard !detach else { throw DockerRuntimeRouteError.invalidRequest("detached exec is not supported") }
        guard let exec = execs[id] else { throw DockerRuntimeRouteError.notFound("exec \(id)") }
        let containerID = try await resolve(exec.containerID)
        var payload: [String: JSONValue] = [
            "id": .string(containerID), "execId": .string(id),
            "args": .array(exec.command.map(JSONValue.string)),
            "env": .array(exec.environment.map(JSONValue.string)), "terminal": .bool(tty),
        ]
        if let cwd = exec.workingDirectory, !cwd.isEmpty { payload["cwd"] = .string(cwd) }
        if let user = exec.user, !user.isEmpty { payload["user"] = .string(user) }
        let collector = GuestStreamCollector(
            stdout: exec.attachStdout,
            stderr: exec.attachStderr
        )
        let connection = try await engine.readyConnection()
        let response = try await connection.request(
            method: "container.exec", payload: .object(payload), onStream: collector.append
        )
        let output = try collector.output(exitCode: response.exitCode ?? -1)
        await broadcastContainer(
            "exec_die", id: containerID,
            extra: ["execID": id, "exitCode": String(output.exitCode)]
        )
        return output
    }

    func streamExec(
        id: String, tty: Bool
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        guard let exec = execs[id] else { throw DockerRuntimeRouteError.notFound("exec \(id)") }
        let containerID = try await resolve(exec.containerID)
        var payload: [String: JSONValue] = [
            "id": .string(containerID), "execId": .string(id),
            "args": .array(exec.command.map(JSONValue.string)),
            "env": .array(exec.environment.map(JSONValue.string)), "terminal": .bool(tty),
        ]
        if let cwd = exec.workingDirectory, !cwd.isEmpty { payload["cwd"] = .string(cwd) }
        if let user = exec.user, !user.isEmpty { payload["user"] = .string(user) }
        let connection = try await engine.readyConnection()
        let requestPayload: JSONValue = .object(payload)
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let control = GuestStreamRequestControl()
            let request = Task {
                do {
                    let response = try await connection.request(
                        method: "container.exec", payload: requestPayload
                    ) { frame in
                        guard let data = frame.data else { return }
                        let result = continuation.yield(
                            .init(stream: frame.stream, data: data, exitCode: nil)
                        )
                        if case .dropped = result {
                            continuation.finish(
                                throwing: DockerRuntimeRouteError.invalidRequest(
                                    "exec client is too slow for the bounded stream buffer"
                                )
                            )
                            control.cancel()
                        }
                    }
                    continuation.yield(
                        .init(stream: nil, data: Data(), exitCode: response.exitCode ?? -1)
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            control.set(request)
            continuation.onTermination = { _ in control.cancel() }
        }
    }

    func attachContainer(
        id: String, stdout: Bool, stderr: Bool
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        let resolved = try await resolve(id)
        let connection = try await engine.readyConnection()
        let payload: JSONValue = .object([
            "id": .string(resolved), "stdout": .bool(stdout), "stderr": .bool(stderr),
        ])
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let control = GuestStreamRequestControl()
            let request = Task {
                do {
                    let response = try await connection.request(
                        method: "container.attach", payload: payload
                    ) { frame in
                        guard let data = frame.data else { return }
                        let result = continuation.yield(
                            .init(stream: frame.stream, data: data, exitCode: nil)
                        )
                        if case .dropped = result {
                            continuation.finish(
                                throwing: DockerRuntimeRouteError.invalidRequest(
                                    "attach client is too slow for the bounded stream buffer"
                                )
                            )
                            control.cancel()
                        }
                    }
                    continuation.yield(
                        .init(stream: nil, data: Data(), exitCode: response.exitCode ?? -1)
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            control.set(request)
            continuation.onTermination = { _ in control.cancel() }
        }
    }

    func logs(id: String, stdout: Bool, stderr: Bool) async throws -> DockerRuntimeProcessOutput {
        let resolved = try await resolve(id)
        let response = try await request(
            "container.logs",
            ["id": .string(resolved), "stdout": .bool(stdout), "stderr": .bool(stderr)]
        )
        let payload: GuestLogsPayload = try decode(response)
        return DockerRuntimeProcessOutput(
            stdout: payload.stdout ?? Data(), stderr: payload.stderr ?? Data(), exitCode: 0
        )
    }

    private func resolve(_ reference: String) async throws -> String {
        if metadata[reference] != nil { return reference }
        let normalized = reference.hasPrefix("/") ? String(reference.dropFirst()) : reference
        let matches = metadata.filter {
            $0.key.hasPrefix(reference) || $0.value.name == normalized
        }.map(\.key)
        if matches.count == 1, let id = matches.first { return id }
        let response = try await request("container.list", [:])
        let guest: GuestContainerListPayload = try decode(response)
        guest.containers.forEach { hydrateMetadata(from: $0) }
        let guestMatches = guest.containers.filter {
            let name = metadata[$0.id]?.name
            return $0.id == reference || $0.id.hasPrefix(reference) || name == normalized
        }.map(\.id)
        guard guestMatches.count == 1, let id = guestMatches.first else {
            throw DockerRuntimeRouteError.notFound("container \(reference)")
        }
        return id
    }

    private func request(_ method: String, _ payload: [String: JSONValue]) async throws -> GuestFrame {
        do {
            return try await engine.readyConnection().request(method: method, payload: .object(payload))
        } catch let error as GuestProtocolError {
            if error.code.contains("not_found") || error.message.contains("not found") {
                throw DockerRuntimeRouteError.notFound(error.message)
            }
            if error.message.contains("used by container") || error.message.contains("multiple tags")
                || error.message.contains("already exists") || error.message.contains("already in use")
                || error.message.contains("running container")
            {
                throw DockerRuntimeRouteError.conflict(error.message)
            }
            throw error
        }
    }

    private func handle(event: GuestFrame) async {
        guard event.method == "container.exit",
            let exit = try? decode(event, as: GuestExitPayload.self)
        else { return }
        metadata[exit.id]?.state = .exited
        metadata[exit.id]?.exitCode = Int32(exit.exitCode)
        pendingPublications.remove(exit.id)
        try? await portPublisher.remove(containerID: exit.id)
        exitCodes.record(id: exit.id, code: Int32(exit.exitCode))
        await broadcastContainer(
            "die", id: exit.id, extra: ["exitCode": String(exit.exitCode)]
        )
        if metadata[exit.id]?.autoRemove == true {
            try? await deleteContainer(id: exit.id, force: true, removeVolumes: true)
        }
    }

    private func dockerContainer(_ guest: GuestContainer) -> DockerRuntimeContainer {
        hydrateMetadata(from: guest)
        let meta = metadata[guest.id]
        let state: EngineContainerState
        switch guest.status {
        case "running": state = .running
        case "stopped", "exited": state = .exited
        default: state = .created
        }
        metadata[guest.id]?.state = state
        return DockerRuntimeContainer(
            id: guest.id, name: meta?.name ?? guest.id, image: guest.image,
            command: meta?.command ?? [], createdAt: guest.createdAt, state: state,
            exitCode: guest.exitCode.map(Int32.init), labels: meta?.labels ?? [:],
            tty: meta?.tty ?? false, ports: meta?.ports ?? []
        )
    }

    private func hydrateMetadata(from guest: GuestContainer) {
        guard metadata[guest.id] == nil, let stored = guest.metadata else { return }
        metadata[guest.id] = Metadata(
            name: stored.name ?? guest.id,
            command: stored.args ?? [],
            labels: stored.labels ?? [:],
            tty: stored.terminal ?? false,
            autoRemove: stored.autoRemove ?? false,
            image: guest.image,
            createdAt: guest.createdAt,
            ports: stored.portBindings ?? [],
            guestPorts: (stored.publishedPorts ?? guest.publishedPorts ?? []).map(\.guestPort),
            state: Self.state(for: guest.status),
            exitCode: guest.exitCode.map(Int32.init)
        )
    }

    private func cachedContainer(id: String) -> DockerRuntimeContainer? {
        guard let meta = metadata[id] else { return nil }
        return DockerRuntimeContainer(
            id: id,
            name: meta.name,
            image: meta.image,
            command: meta.command,
            createdAt: meta.createdAt,
            state: meta.state,
            exitCode: meta.exitCode,
            labels: meta.labels,
            tty: meta.tty,
            ports: meta.ports
        )
    }

    private func restoreRuntimeState() async throws {
        let response = try await request("container.list", [:])
        let payload: GuestContainerListPayload = try decode(response)
        payload.containers.forEach { hydrateMetadata(from: $0) }
        for container in payload.containers
        where container.status == "stopped" || container.status == "exited" {
            if metadata[container.id]?.autoRemove == true {
                try await deleteContainer(id: container.id, force: true, removeVolumes: true)
            }
        }
        reservedGuestPorts.removeAll()
        for container in payload.containers.sorted(by: { $0.id < $1.id }) {
            guard var meta = metadata[container.id] else { continue }
            let reusable =
                meta.guestPorts.count == meta.ports.count
                && meta.guestPorts.allSatisfy(PublishedPortProxyRange.ports.contains)
                && Set(meta.guestPorts).isDisjoint(with: reservedGuestPorts)
            if !reusable {
                guard
                    let replacement = Self.lowestAvailableGuestPorts(
                        count: meta.ports.count,
                        range: PublishedPortProxyRange.ports,
                        excluding: reservedGuestPorts
                    )
                else {
                    throw DockerRuntimeRouteError.conflict(
                        "published guest port range is exhausted during recovery"
                    )
                }
                meta.guestPorts = replacement
                metadata[container.id] = meta
            }
            reservedGuestPorts.formUnion(meta.guestPorts)
        }
        for container in payload.containers where container.status == "running" {
            guard let bindings = metadata[container.id]?.ports, !bindings.isEmpty else { continue }
            let guestPorts = container.metadata?.publishedPorts ?? container.publishedPorts ?? []
            guard guestPorts.count == bindings.count else { continue }
            let published = try await portPublisher.publish(
                containerID: container.id,
                bindings: bindings,
                guestPorts: guestPorts.map(\.guestPort)
            )
            metadata[container.id]?.ports = published
            try await persistPortBindings(containerID: container.id, bindings: published)
        }
    }

    private func persistPortBindings(
        containerID: String, bindings: [DockerRuntimePortBinding]
    ) async throws {
        _ = try await request(
            "container.metadata.update",
            [
                "id": .string(containerID),
                "portBindings": .array(bindings.map(Self.portBindingJSON)),
            ]
        )
    }

    private func vmnetHostSource(required: Bool) async throws -> String {
        guard required else { return "" }
        guard let address = await engine.hostGatewayAddress() else {
            throw PersistentEngineError.invalidMachineSnapshot("engine IP address is unavailable")
        }
        return address
    }

    private static func portBindingJSON(_ binding: DockerRuntimePortBinding) -> JSONValue {
        var object: [String: JSONValue] = [
            "containerPort": .number(Double(binding.containerPort)),
            "protocol": .string(binding.proto),
            "hostIP": .string(binding.hostIP),
        ]
        if let hostPort = binding.hostPort { object["hostPort"] = .number(Double(hostPort)) }
        return .object(object)
    }

    private func releaseGuestPorts(containerID: String) {
        guard let ports = metadata[containerID]?.guestPorts else { return }
        reservedGuestPorts.subtract(ports)
    }

    private static func state(for status: String) -> EngineContainerState {
        switch status {
        case "running": .running
        case "stopped", "exited": .exited
        default: .created
        }
    }

    private static func normalizedContainerName(_ name: String) -> String {
        name.hasPrefix("/") ? String(name.dropFirst()) : name
    }

    private func decode<T: Decodable>(_ frame: GuestFrame, as type: T.Type = T.self) throws -> T {
        guard let payload = frame.payload else { throw GuestProtocolError(code: "invalid_response", message: "missing payload") }
        let data = try JSONEncoder().encode(payload)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private static func makeID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func dockerImage(_ image: GuestImageDetailPayload) -> DockerRuntimeImage {
        DockerRuntimeImage(
            reference: image.references.first ?? image.digest,
            digest: image.id,
            references: image.references,
            createdAt: image.createdAt,
            size: image.size,
            labels: image.labels ?? [:],
            rootFSLayers: image.rootFSLayers ?? []
        )
    }

    private static func dockerImageDelete(_ result: GuestImageDeletePayload) -> DockerRuntimeImageDelete {
        DockerRuntimeImageDelete(
            deleted: result.deleted ?? [],
            untagged: result.untagged ?? [],
            reclaimed: result.reclaimed ?? 0
        )
    }

    private static func normalizedRegistryReference(_ reference: String) -> String {
        if reference.hasPrefix("sha256:") { return reference }
        if reference.count >= 4, reference.allSatisfy({ $0.isHexDigit }) { return reference }
        let first = reference.split(separator: "/", maxSplits: 1).first.map(String.init) ?? reference
        var normalized: String
        if reference.contains("/"), first.contains(".") || first.contains(":") || first == "localhost" {
            normalized = reference
        } else {
            normalized = reference.contains("/") ? "docker.io/\(reference)" : "docker.io/library/\(reference)"
        }
        let last = normalized.split(separator: "/").last.map(String.init) ?? normalized
        if !normalized.contains("@"), !last.contains(":") { normalized += ":latest" }
        return normalized
    }

    private func broadcastContainer(
        _ action: String,
        id: String,
        extra: [String: String] = [:]
    ) async {
        guard let broadcaster, let meta = metadata[id] else { return }
        await broadcaster.broadcast(
            DockerEvent.simpleEvent(
                id: id, type: "container", status: action,
                image: meta.image, name: meta.name, labels: meta.labels,
                extraAttributes: extra
            )
        )
    }

}

struct GuestRuntimeLifecycle: LifecycleHandler {
    let runtime: GuestRuntime

    func shutdownAsync(_ application: Application) async {
        await runtime.stopEventMonitor()
    }
}
