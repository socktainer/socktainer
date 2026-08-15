import Foundation
import NIOCore
import Vapor

enum EngineContainerState: String, Sendable, Equatable {
    case created
    case running
    case exited
}

/// The Docker-facing operations needed by the runtime benchmark and its live
/// lifecycle test. GuestRuntime implements this protocol; the route layer owns
/// only Docker request and response semantics.
protocol DockerRuntimeRouteBackend: Sendable {
    func pullImage(
        reference: String, platform: String?, auth: DockerRegistryAuth?
    ) async throws -> DockerRuntimeImage
    func listImages() async throws -> [DockerRuntimeImage]
    func inspectImage(reference: String) async throws -> DockerRuntimeImage
    func deleteImage(reference: String, force: Bool) async throws -> DockerRuntimeImageDelete
    func pruneImages(all: Bool) async throws -> DockerRuntimeImageDelete
    func tagImage(source: String, target: String) async throws
    func createContainer(_ request: DockerRuntimeContainerCreate) async throws -> DockerRuntimeContainer
    func startContainer(id: String) async throws
    func killContainer(id: String, signal: UInt32) async throws
    func waitContainer(id: String, condition: ContainerWaitCondition) async throws -> Int32
    func deleteContainer(id: String, force: Bool, removeVolumes: Bool) async throws
    func inspectContainer(id: String) async throws -> DockerRuntimeContainer
    func listContainers(showAll: Bool) async throws -> [DockerRuntimeContainer]
    func createExec(_ request: DockerRuntimeExecCreate) async throws -> String
    func startExec(id: String, detach: Bool, tty: Bool) async throws -> DockerRuntimeProcessOutput
    func streamExec(id: String, tty: Bool) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error>
    func logs(id: String, stdout: Bool, stderr: Bool) async throws -> DockerRuntimeProcessOutput
    func containerAutoRemove(id: String) async throws -> Bool
    func attachContainer(
        id: String, stdout: Bool, stderr: Bool
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error>
}

struct DockerRuntimeProcessFrame: Sendable {
    let stream: GuestStream?
    let data: Data
    let exitCode: Int32?
}

struct DockerRegistryAuth: Codable, Sendable, Equatable {
    let username: String?
    let password: String?
    let identitytoken: String?
    let serveraddress: String?
}

extension DockerRuntimeRouteBackend {
    func containerAutoRemove(id: String) async throws -> Bool { false }
    func killContainer(id: String, signal: UInt32) async throws {
        throw DockerRuntimeRouteError.invalidRequest("container signals are not supported")
    }

    func streamExec(
        id: String, tty: Bool
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        let output = try await startExec(id: id, detach: false, tty: tty)
        return AsyncThrowingStream { continuation in
            if !output.stdout.isEmpty {
                continuation.yield(.init(stream: .stdout, data: output.stdout, exitCode: nil))
            }
            if !output.stderr.isEmpty {
                continuation.yield(.init(stream: .stderr, data: output.stderr, exitCode: nil))
            }
            continuation.yield(.init(stream: nil, data: Data(), exitCode: output.exitCode))
            continuation.finish()
        }
    }

    func attachContainer(
        id: String, stdout: Bool, stderr: Bool
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        let output = try await logs(id: id, stdout: stdout, stderr: stderr)
        return AsyncThrowingStream { continuation in
            if !output.stdout.isEmpty {
                continuation.yield(.init(stream: .stdout, data: output.stdout, exitCode: nil))
            }
            if !output.stderr.isEmpty {
                continuation.yield(.init(stream: .stderr, data: output.stderr, exitCode: nil))
            }
            continuation.yield(.init(stream: nil, data: Data(), exitCode: output.exitCode))
            continuation.finish()
        }
    }
}

struct DockerRuntimeImage: Sendable, Equatable {
    let reference: String
    let digest: String
    let references: [String]
    let createdAt: Date
    let size: Int64
    let labels: [String: String]
    let rootFSLayers: [String]

    init(
        reference: String, digest: String, references: [String] = [],
        createdAt: Date = Date(timeIntervalSince1970: 0), size: Int64 = 0,
        labels: [String: String] = [:], rootFSLayers: [String] = []
    ) {
        self.reference = reference
        self.digest = digest
        self.references = references.isEmpty ? [reference] : references
        self.createdAt = createdAt
        self.size = size
        self.labels = labels
        self.rootFSLayers = rootFSLayers
    }
}

struct DockerRuntimeImageDelete: Sendable, Equatable {
    let deleted: [String]
    let untagged: [String]
    let reclaimed: Int64
}

struct DockerRuntimeMount: Codable, Sendable, Equatable {
    let source: String
    let target: String
    let readOnly: Bool
    var volumeName: String? = nil
}

struct DockerRuntimePortBinding: Codable, Sendable, Equatable {
    let containerPort: Int
    let proto: String
    let hostIP: String
    let hostPort: Int?

    enum CodingKeys: String, CodingKey {
        case containerPort
        case proto = "protocol"
        case hostIP
        case hostPort
    }

    init(containerPort: Int, proto: String, hostIP: String, hostPort: Int?) {
        self.containerPort = containerPort
        self.proto = proto
        self.hostIP = hostIP
        self.hostPort = hostPort
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        containerPort = try values.decode(Int.self, forKey: .containerPort)
        proto = try values.decodeIfPresent(String.self, forKey: .proto) ?? "tcp"
        hostIP = try values.decodeIfPresent(String.self, forKey: .hostIP) ?? "0.0.0.0"
        hostPort = try values.decodeIfPresent(Int.self, forKey: .hostPort)
    }
}

struct DockerRuntimeContainerCreate: Sendable, Equatable {
    let name: String?
    let image: String
    let command: [String]
    let entrypoint: [String]?
    let cmd: [String]?
    let environment: [String]
    let workingDirectory: String?
    let user: String?
    let hostname: String?
    let labels: [String: String]
    let tty: Bool
    let autoRemove: Bool
    let mounts: [DockerRuntimeMount]
    let ports: [DockerRuntimePortBinding]
}

struct DockerRuntimeContainer: Sendable, Equatable {
    let id: String
    let name: String
    let image: String
    let command: [String]
    let createdAt: Date
    let state: EngineContainerState
    let exitCode: Int32?
    let labels: [String: String]
    let tty: Bool
    let ports: [DockerRuntimePortBinding]
}

struct DockerRuntimeExecCreate: Sendable, Equatable {
    let containerID: String
    let command: [String]
    let environment: [String]
    let workingDirectory: String?
    let user: String?
    let tty: Bool
    let attachStdout: Bool
    let attachStderr: Bool
}

struct DockerRuntimeProcessOutput: Sendable, Equatable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32

    init(stdout: Data = Data(), stderr: Data = Data(), exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

enum DockerRuntimeRouteError: Error, Equatable {
    case notFound(String)
    case conflict(String)
    case invalidRequest(String)
}

private struct DockerStopTimeout: Error {}

private actor DockerRuntimeExecState {
    struct Entry: Sendable {
        let request: DockerRuntimeExecCreate
        var running = false
        var exitCode: Int32?
    }

    private var entries: [String: Entry] = [:]

    func insert(id: String, request: DockerRuntimeExecCreate) {
        entries[id] = Entry(request: request)
    }

    func entry(id: String) -> Entry? { entries[id] }

    func markRunning(id: String) throws {
        guard var entry = entries[id] else { throw DockerRuntimeRouteError.notFound("Exec instance (id)") }
        guard !entry.running, entry.exitCode == nil else {
            throw DockerRuntimeRouteError.conflict("Exec instance (id) has already been started")
        }
        entry.running = true
        entries[id] = entry
    }

    func finish(id: String, exitCode: Int32) {
        guard var entry = entries[id] else { return }
        entry.running = false
        entry.exitCode = exitCode
        entries[id] = entry
    }
}

struct DockerRuntimeRoutes: RouteCollection {
    let backend: any DockerRuntimeRouteBackend
    let volumeClient: (any ClientVolumeProtocol)?
    private let execState = DockerRuntimeExecState()

    init(
        backend: any DockerRuntimeRouteBackend,
        volumeClient: (any ClientVolumeProtocol)? = nil
    ) {
        self.backend = backend
        self.volumeClient = volumeClient
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/create", use: pullImage)
        try routes.registerVersionedRoute(.GET, pattern: "/images/json", use: listImages)
        try routes.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/json", use: inspectImage)
        try routes.registerVersionedRoute(.DELETE, pattern: "/images/{name:.*}", use: deleteImage)
        try routes.registerVersionedRoute(.POST, pattern: "/images/prune", use: pruneImages)
        try routes.registerVersionedRoute(.POST, pattern: "/images/{name:.*}/tag", use: tagImage)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/create", use: createContainer)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/start", use: startContainer)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/stop", use: stopContainer)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/kill", use: killContainer)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/wait", use: waitContainer)
        try routes.registerVersionedRoute(.DELETE, pattern: "/containers/{id}", use: deleteContainer)
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id}/json", use: inspectContainer)
        try routes.registerVersionedRoute(.GET, pattern: "/containers/json", use: listContainers)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/exec", use: createExec)
        try routes.registerVersionedRoute(.POST, pattern: "/exec/{id}/start", use: startExec)
        try routes.registerVersionedRoute(.GET, pattern: "/exec/{id}/json", use: inspectExec)
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id}/logs", use: logs)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/attach", use: attach)
    }

    private func pullImage(_ req: Request) async throws -> Response {
        if req.query[String.self, at: "fromSrc"] != nil {
            throw Abort(.notImplemented, reason: "Image import is not implemented by the persistent runtime")
        }
        let fromImage = try requiredQuery("fromImage", request: req)
        let tag = req.query[String.self, at: "tag"]
        let reference = Self.imageReference(fromImage: fromImage, tag: tag)
        let auth = try Self.registryAuth(req.headers.first(name: "X-Registry-Auth"))
        let image = try await call {
            try await backend.pullImage(
                reference: reference,
                platform: req.query[String.self, at: "platform"],
                auth: auth
            )
        }
        struct PullProgress: Encodable {
            let status: String
            let id: String
        }
        var body = try JSONEncoder().encode(PullProgress(status: "Downloaded newer image for \(image.reference)", id: image.digest))
        body.append(0x0A)
        let response = Response(status: .ok, body: .init(data: body))
        response.headers.contentType = .json
        return response
    }

    private func listImages(_ req: Request) async throws -> Response {
        var images = try await call { try await backend.listImages() }
        if let raw = req.query[String.self, at: "filters"],
            let data = raw.data(using: .utf8),
            let filters = try? JSONDecoder().decode([String: [String: Bool]].self, from: data),
            let references = filters["reference"], !references.isEmpty
        {
            images = images.filter { image in
                image.references.contains { candidate in
                    references.keys.contains { Self.matchesReference(candidate, pattern: $0) }
                }
            }
        }
        return try jsonResponse(.ok, images.map(ImageSummary.init))
    }

    private func inspectImage(_ req: Request) async throws -> Response {
        let reference = try requiredParameter("name", request: req)
        let image = try await call { try await backend.inspectImage(reference: reference) }
        return try jsonResponse(.ok, ImageInspectResponse(image))
    }

    private func deleteImage(_ req: Request) async throws -> Response {
        let reference = try requiredParameter("name", request: req)
        let result = try await call {
            try await backend.deleteImage(
                reference: reference,
                force: Self.mobyBool(req.query[String.self, at: "force"])
            )
        }
        return try jsonResponse(.ok, Self.imageDeleteItems(result))
    }

    private func pruneImages(_ req: Request) async throws -> Response {
        let all = Self.pruneAll(req.query[String.self, at: "filters"])
        let result = try await call { try await backend.pruneImages(all: all) }
        return try jsonResponse(
            .ok,
            ImagePruneResponse(
                ImagesDeleted: Self.imageDeleteItems(result),
                SpaceReclaimed: result.reclaimed
            )
        )
    }

    private func tagImage(_ req: Request) async throws -> Response {
        let source = try requiredParameter("name", request: req)
        let repo = try requiredQuery("repo", request: req)
        let tag = req.query[String.self, at: "tag"]
        let target = Self.imageReference(fromImage: repo, tag: tag)
        try await call { try await backend.tagImage(source: source, target: target) }
        return Response(status: .created)
    }

    private func createContainer(_ req: Request) async throws -> Response {
        let body: CreateRequest
        do {
            guard let buffer = try await req.body.collect(max: req.application.routes.defaultMaxBodySize.value).get(),
                let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)
            else {
                throw DockerRuntimeRouteError.invalidRequest("request body is required")
            }
            try Self.validateCreateOptions(data)
            body = try JSONDecoder().decode(CreateRequest.self, from: data)
        } catch let abort as Abort {
            throw abort
        } catch {
            throw Abort(.badRequest, reason: "Invalid container create request: \(error)")
        }
        guard !body.Image.isEmpty else { throw Abort(.badRequest, reason: "No image specified") }
        let mounts = try await mounts(from: body.HostConfig)
        let request = DockerRuntimeContainerCreate(
            name: req.query[String.self, at: "name"],
            image: body.Image,
            command: (body.Entrypoint ?? []) + (body.Cmd ?? []),
            entrypoint: body.Entrypoint,
            cmd: body.Cmd,
            environment: body.Env ?? [],
            workingDirectory: body.WorkingDir,
            user: body.User,
            hostname: body.Hostname,
            labels: body.Labels ?? [:],
            tty: body.Tty ?? false,
            autoRemove: body.HostConfig?.AutoRemove ?? false,
            mounts: mounts,
            ports: Self.ports(from: body.HostConfig)
        )
        let container = try await call { try await backend.createContainer(request) }
        if let volumes = volumeClient as? RuntimeVolumeService {
            do {
                try await volumes.retain(
                    names: Set(mounts.compactMap(\.volumeName)), containerID: container.id)
            } catch {
                try? await backend.deleteContainer(
                    id: container.id, force: true, removeVolumes: false)
                throw error
            }
        }
        return try jsonResponse(.created, RESTContainerCreate(Id: container.id, Warnings: []))
    }

    private func startContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        try await call { try await backend.startContainer(id: id) }
        return Response(status: .noContent)
    }

    private func waitContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let raw = req.query[String.self, at: "condition"]
        let condition: ContainerWaitCondition
        if let raw {
            guard let parsed = ContainerWaitCondition(rawValue: raw) else {
                throw Abort(.badRequest, reason: "Unsupported wait condition: \(raw)")
            }
            condition = parsed
        } else {
            condition = .default
        }
        let backend = self.backend
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(
            status: .ok,
            headers: headers,
            body: .init(managedAsyncStream: { writer in
                try await writer.writeBuffer(ByteBuffer(string: " "))
                let exitCode = try await backend.waitContainer(id: id, condition: condition)
                let data = try JSONEncoder().encode(RESTContainerWait(statusCode: Int64(exitCode)))
                try await writer.writeBuffer(ByteBuffer(bytes: data))
            })
        )
    }

    private func stopContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let container = try await call { try await backend.inspectContainer(id: id) }
        guard container.state == .running else { return Response(status: .notModified) }
        let signalText = req.query[String.self, at: "signal"] ?? "TERM"
        guard let signal = DockerSignal.number(signalText) else {
            throw Abort(.badRequest, reason: "Invalid stop signal: \(signalText)")
        }
        let timeout = max(0, req.query[Int.self, at: "t"] ?? 10)
        try await call { try await backend.killContainer(id: id, signal: signal) }
        let wait = Task { try await backend.waitContainer(id: id, condition: .notRunning) }
        do {
            _ = try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { try await wait.value }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw DockerStopTimeout()
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw DockerStopTimeout()
                }
                return result
            }
        } catch is DockerStopTimeout {
            try await call { try await backend.killContainer(id: id, signal: 9) }
            _ = try await wait.value
        }
        return Response(status: .noContent)
    }

    private func killContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let signalText = req.query[String.self, at: "signal"] ?? "KILL"
        guard let signal = DockerSignal.number(signalText) else {
            throw Abort(.badRequest, reason: "Invalid signal: \(signalText)")
        }
        try await call { try await backend.killContainer(id: id, signal: signal) }
        return Response(status: .noContent)
    }

    private func deleteContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        try await call {
            try await backend.deleteContainer(
                id: id,
                force: Self.mobyBool(req.query[String.self, at: "force"]),
                removeVolumes: Self.mobyBool(req.query[String.self, at: "v"])
            )
        }
        if let volumes = volumeClient as? RuntimeVolumeService {
            try await volumes.release(containerID: id)
        }
        return Response(status: .noContent)
    }

    private func inspectContainer(_ req: Request) async throws -> Response {
        let container = try await call { try await backend.inspectContainer(id: requiredParameter("id", request: req)) }
        return try jsonResponse(.ok, InspectResponse(container))
    }

    private func listContainers(_ req: Request) async throws -> Response {
        var containers = try await call {
            try await backend.listContainers(showAll: Self.mobyBool(req.query[String.self, at: "all"]))
        }
        if let raw = req.query[String.self, at: "filters"] {
            let filters = try Self.containerFilters(raw)
            containers = containers.filter { Self.matches($0, filters: filters) }
        }
        return try jsonResponse(.ok, containers.map(ListResponse.init))
    }

    private func createExec(_ req: Request) async throws -> Response {
        let containerID = try requiredParameter("id", request: req)
        let body = try req.content.decode(ExecCreateRequest.self)
        guard let command = body.Cmd, !command.isEmpty else {
            throw Abort(.badRequest, reason: "No exec command specified")
        }
        let request = DockerRuntimeExecCreate(
            containerID: containerID,
            command: command,
            environment: body.Env ?? [],
            workingDirectory: body.WorkingDir,
            user: body.User,
            tty: body.Tty ?? false,
            attachStdout: body.AttachStdout ?? true,
            attachStderr: body.AttachStderr ?? true
        )
        let id = try await call { try await backend.createExec(request) }
        await execState.insert(id: id, request: request)
        return try jsonResponse(.created, CreateExecResponse(Id: id))
    }

    private func startExec(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        guard let entry = await execState.entry(id: id) else {
            throw Abort(.notFound, reason: "Exec instance not found: \(id)")
        }
        let body = try req.content.decode(ExecStartRequest.self)
        try await call { try await execState.markRunning(id: id) }
        let tty = body.Tty ?? entry.request.tty
        if body.Detach ?? false {
            do {
                _ = try await call { try await backend.startExec(id: id, detach: true, tty: tty) }
                await execState.finish(id: id, exitCode: 0)
                return Response(status: .ok)
            } catch {
                await execState.finish(id: id, exitCode: -1)
                throw error
            }
        }
        let stream = try await call { try await backend.streamExec(id: id, tty: tty) }
        var headers = HTTPHeaders()
        headers.contentType = HTTPMediaType(type: "application", subType: "vnd.docker.raw-stream")
        let state = execState
        let response = Response(
            status: .ok,
            headers: headers,
            body: .init(managedAsyncStream: { writer in
                do {
                    var exitCode: Int32 = -1
                    for try await frame in stream {
                        if let code = frame.exitCode {
                            exitCode = code
                        } else if tty {
                            try await writer.writeBuffer(ByteBuffer(data: frame.data))
                        } else {
                            let streamID: UInt8 = frame.stream == .stderr ? 2 : 1
                            try await writer.writeBuffer(
                                ByteBuffer(data: Self.frame(frame.data, stream: streamID))
                            )
                        }
                    }
                    await state.finish(id: id, exitCode: exitCode)
                } catch {
                    await state.finish(id: id, exitCode: -1)
                    throw error
                }
            })
        )
        if req.headers.first(name: "Upgrade")?.lowercased() == "tcp" {
            response.status = .switchingProtocols
            response.headers.replaceOrAdd(name: "Connection", value: "Upgrade")
            response.headers.replaceOrAdd(name: "Upgrade", value: "tcp")
        }
        return response
    }

    private func inspectExec(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        guard let entry = await execState.entry(id: id) else {
            throw Abort(.notFound, reason: "Exec instance not found: \(id)")
        }
        return try jsonResponse(.ok, ExecInspectResponse(id: id, entry: entry))
    }

    private func logs(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let unsupported =
            Self.mobyBool(req.query[String.self, at: "follow"])
            || Self.mobyBool(req.query[String.self, at: "timestamps"])
            || Self.mobyBool(req.query[String.self, at: "details"])
            || req.query[String.self, at: "since"].map { $0 != "0" } == true
            || req.query[String.self, at: "until"] != nil
            || req.query[String.self, at: "tail"].map { $0 != "all" } == true
        if unsupported {
            throw Abort(.notImplemented, reason: "Requested Docker log filtering or follow mode is not implemented")
        }
        let stdout = Self.mobyBool(req.query[String.self, at: "stdout"])
        let stderr = Self.mobyBool(req.query[String.self, at: "stderr"])
        guard stdout || stderr else {
            throw Abort(.badRequest, reason: "Bad parameters: you must choose at least one stream")
        }
        let container = try await call { try await backend.inspectContainer(id: id) }
        let output = try await call { try await backend.logs(id: id, stdout: stdout, stderr: stderr) }
        return Self.streamResponse(output: output, tty: container.tty)
    }

    private func attach(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        if Self.mobyBool(req.query[String.self, at: "stdin"]) {
            throw Abort(.notImplemented, reason: "Interactive attach stdin is not implemented")
        }
        let tty = try await inspectContainer(id: id).tty
        let backend = self.backend
        let stdout = req.query[String.self, at: "stdout"].map(Self.mobyBool) ?? true
        let stderr = req.query[String.self, at: "stderr"].map(Self.mobyBool) ?? true
        let stream = try await call {
            try await backend.attachContainer(id: id, stdout: stdout, stderr: stderr)
        }
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "Upgrade")
        headers.add(name: "Upgrade", value: "tcp")
        headers.contentType = HTTPMediaType(type: "application", subType: "vnd.docker.raw-stream")
        return Response(
            status: .switchingProtocols,
            headers: headers,
            body: .init(managedAsyncStream: { writer in
                // Send the upgrade response before Docker issues the separate
                // container-start request. Attach must not start the container.
                try await writer.writeBuffer(ByteBuffer())
                for try await frame in stream {
                    guard frame.exitCode == nil else { continue }
                    if tty {
                        try await writer.writeBuffer(ByteBuffer(data: frame.data))
                    } else {
                        let streamID: UInt8 = frame.stream == .stderr ? 2 : 1
                        try await writer.writeBuffer(
                            ByteBuffer(data: Self.frame(frame.data, stream: streamID))
                        )
                    }
                }
            })
        )
    }

    private func call<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() } catch let error as DockerRuntimeRouteError {
            switch error {
            case .notFound(let message): throw Abort(.notFound, reason: message)
            case .conflict(let message): throw Abort(.conflict, reason: message)
            case .invalidRequest(let message): throw Abort(.badRequest, reason: message)
            }
        }
    }

    private func inspectContainer(id: String) async throws -> DockerRuntimeContainer {
        // Keep generic error mapping outside the escaping response stream closure.
        // Swift 6.3.3 otherwise stalls in ClosureLifetimeFixup while compiling attach.
        try await call { try await backend.inspectContainer(id: id) }
    }

    private func requiredParameter(_ name: String, request: Request) throws -> String {
        guard let value = request.parameters.get(name), !value.isEmpty else {
            throw Abort(.badRequest, reason: "Missing \(name)")
        }
        return value
    }

    private func requiredQuery(_ name: String, request: Request) throws -> String {
        guard let value = request.query[String.self, at: name], !value.isEmpty else {
            throw Abort(.badRequest, reason: "Missing \(name)")
        }
        return value
    }

    private func jsonResponse<T: Encodable>(_ status: HTTPResponseStatus, _ value: T) throws -> Response {
        let response = Response(status: status, body: .init(data: try JSONEncoder().encode(value)))
        response.headers.contentType = .json
        return response
    }

    private static func streamResponse(output: DockerRuntimeProcessOutput, tty: Bool) -> Response {
        var data = Data()
        if tty {
            data.append(output.stdout)
            data.append(output.stderr)
        } else {
            data.append(frame(output.stdout, stream: 1))
            data.append(frame(output.stderr, stream: 2))
        }
        let response = Response(status: .ok, body: .init(data: data))
        response.headers.contentType = HTTPMediaType(type: "application", subType: "vnd.docker.raw-stream")
        return response
    }

    private static func frame(_ payload: Data, stream: UInt8) -> Data {
        guard !payload.isEmpty else { return Data() }
        var result = Data([stream, 0, 0, 0])
        var size = UInt32(payload.count).bigEndian
        result.append(Data(bytes: &size, count: 4))
        result.append(payload)
        return result
    }

    private static func mobyBool(_ value: String?) -> Bool {
        guard let value else { return false }
        return value == "1" || value.lowercased() == "true"
    }

    private static func imageReference(fromImage: String, tag: String?) -> String {
        guard let tag, !tag.isEmpty, !fromImage.contains("@") else { return fromImage }
        if tag.hasPrefix("sha256:") { return "\(fromImage)@\(tag)" }
        return "\(fromImage):\(tag)"
    }

    private static func validateCreateOptions(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DockerRuntimeRouteError.invalidRequest("request body must be a JSON object")
        }
        for key in [
            "AttachStdin", "OpenStdin", "StdinOnce", "NetworkDisabled", "Volumes", "Healthcheck",
            "Domainname", "MacAddress", "OnBuild", "Shell",
        ] where object[key].map({ !isDefaultJSONValue($0) }) == true {
            throw Abort(.notImplemented, reason: "Container create option \(key) is not implemented")
        }
        if let signal = object["StopSignal"] as? String,
            !signal.isEmpty, signal.uppercased() != "SIGTERM", signal != "15"
        {
            throw Abort(.notImplemented, reason: "Container create option StopSignal is not implemented")
        }
        guard let host = object["HostConfig"] as? [String: Any] else { return }
        for key in [
            "Privileged", "ReadonlyRootfs", "OomKillDisable", "PublishAllPorts", "Init", "Memory",
            "MemorySwap", "MemoryReservation", "NanoCpus", "CpuShares", "CpuPeriod",
            "CpuQuota", "CpuRealtimePeriod", "CpuRealtimeRuntime", "CpusetCpus", "CpusetMems",
            "PidsLimit", "BlkioWeight", "BlkioWeightDevice", "BlkioDeviceReadBps",
            "BlkioDeviceWriteBps", "BlkioDeviceReadIOps", "BlkioDeviceWriteIOps", "CapAdd", "CapDrop",
            "Devices", "DeviceCgroupRules", "DeviceRequests", "Ulimits", "SecurityOpt", "GroupAdd", "Dns",
            "DnsOptions", "DnsSearch", "ExtraHosts", "Links", "VolumesFrom", "Tmpfs", "Sysctls",
            "StorageOpt", "CgroupParent",
        ] where host[key].map({ !isDefaultJSONValue($0) }) == true {
            throw Abort(.notImplemented, reason: "HostConfig option \(key) is not implemented")
        }
        if let swappiness = host["MemorySwappiness"] as? NSNumber,
            swappiness.intValue != -1, swappiness.intValue != 0
        {
            throw Abort(.notImplemented, reason: "HostConfig option MemorySwappiness is not implemented")
        }
        if let mode = host["NetworkMode"] as? String,
            !mode.isEmpty, mode != "default", mode != "bridge"
        {
            throw Abort(.notImplemented, reason: "NetworkMode \(mode) is not implemented")
        }
        for key in ["PidMode", "UTSMode", "UsernsMode"] {
            if let value = host[key] as? String, !value.isEmpty {
                throw Abort(.notImplemented, reason: "HostConfig option \(key) is not implemented")
            }
        }
        if let mode = host["IpcMode"] as? String, !mode.isEmpty, mode != "private" {
            throw Abort(.notImplemented, reason: "IpcMode \(mode) is not implemented")
        }
        if let mode = host["CgroupnsMode"] as? String, !mode.isEmpty, mode != "private" {
            throw Abort(.notImplemented, reason: "CgroupnsMode \(mode) is not implemented")
        }
        if let runtime = host["Runtime"] as? String, !runtime.isEmpty, runtime != "runc" {
            throw Abort(.notImplemented, reason: "Runtime \(runtime) is not implemented")
        }
        if let policy = host["RestartPolicy"] as? [String: Any],
            let name = policy["Name"] as? String, !name.isEmpty, name != "no"
        {
            throw Abort(.notImplemented, reason: "RestartPolicy \(name) is not implemented")
        }
    }

    private static func isDefaultJSONValue(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let value = value as? Bool { return !value }
        if let value = value as? NSNumber { return value.doubleValue == 0 }
        if let value = value as? String { return value.isEmpty }
        if let value = value as? [Any] { return value.isEmpty }
        if let value = value as? [String: Any] {
            return value.isEmpty || value.values.allSatisfy(isDefaultJSONValue)
        }
        return false
    }

    private static func registryAuth(_ value: String?) throws -> DockerRegistryAuth? {
        guard let value, !value.isEmpty else { return nil }
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized),
            let auth = try? JSONDecoder().decode(DockerRegistryAuth.self, from: data)
        else {
            throw Abort(.badRequest, reason: "Invalid X-Registry-Auth header")
        }
        return auth
    }

    private static func matchesReference(_ reference: String, pattern: String) -> Bool {
        if pattern == reference { return true }
        if pattern.hasSuffix("*") {
            return reference.hasPrefix(String(pattern.dropLast()))
        }
        return reference.contains(pattern)
    }

    private static func pruneAll(_ rawFilters: String?) -> Bool {
        guard let rawFilters, let data = rawFilters.data(using: .utf8) else { return false }
        if let filters = try? JSONDecoder().decode([String: [String: Bool]].self, from: data) {
            return filters["dangling"]?["false"] != nil
        }
        if let filters = try? JSONDecoder().decode([String: [String]].self, from: data) {
            return filters["dangling"]?.contains("false") == true
        }
        return false
    }

    private static func containerFilters(_ raw: String) throws -> [String: [String]] {
        guard let data = raw.data(using: .utf8) else {
            throw Abort(.badRequest, reason: "Invalid container filters")
        }
        if let filters = try? JSONDecoder().decode([String: [String]].self, from: data) {
            return filters
        }
        if let filters = try? JSONDecoder().decode([String: [String: Bool]].self, from: data) {
            return filters.mapValues { $0.compactMap { $0.value ? $0.key : nil } }
        }
        throw Abort(.badRequest, reason: "Invalid container filters")
    }

    private static func matches(
        _ container: DockerRuntimeContainer,
        filters: [String: [String]]
    ) -> Bool {
        filters.allSatisfy { key, values in
            guard !values.isEmpty else { return true }
            switch key {
            case "id":
                return values.contains { container.id.hasPrefix($0) }
            case "name":
                return values.contains {
                    container.name.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                }
            case "status":
                return values.contains(container.state.rawValue)
            case "ancestor":
                return values.contains {
                    container.image == $0 || container.image.hasPrefix($0)
                }
            case "label":
                return values.contains { expression in
                    let parts = expression.split(separator: "=", maxSplits: 1).map(String.init)
                    guard let actual = container.labels[parts[0]] else { return false }
                    return parts.count == 1 || actual == parts[1]
                }
            default:
                return false
            }
        }
    }

    private static func imageDeleteItems(_ result: DockerRuntimeImageDelete) -> [ImageDeleteItem] {
        result.untagged.map { ImageDeleteItem(Deleted: nil, Untagged: $0) }
            + result.deleted.map { ImageDeleteItem(Deleted: $0, Untagged: nil) }
    }

    private func mounts(from host: CreateHostConfig?) async throws -> [DockerRuntimeMount] {
        var result: [DockerRuntimeMount] = []
        for bind in host?.Binds ?? [] {
            let components = bind.split(separator: ":", maxSplits: 2).map(String.init)
            guard components.count >= 2, components[1].hasPrefix("/") else {
                throw Abort(.badRequest, reason: "Invalid bind mount: \(bind)")
            }
            let source = try await resolveMountSource(components[0])
            result.append(
                DockerRuntimeMount(
                    source: source.path, target: components[1], readOnly: components.count == 3 && components[2].split(separator: ",").contains("ro"), volumeName: source.volumeName
                ))
        }
        for mount in host?.Mounts ?? [] {
            guard mount.`Type` == "bind" || mount.`Type` == "volume" else {
                throw Abort(.notImplemented, reason: "Mount type \(mount.`Type`) is not supported")
            }
            guard let source = mount.Source, mount.Target.hasPrefix("/") else {
                throw Abort(.badRequest, reason: "Invalid bind mount")
            }
            let resolved = try await resolveMountSource(source)
            result.append(DockerRuntimeMount(source: resolved.path, target: mount.Target, readOnly: mount.ReadOnly ?? false, volumeName: resolved.volumeName))
        }
        return result
    }

    private func resolveMountSource(_ source: String) async throws -> (path: String, volumeName: String?) {
        if source.hasPrefix("/") {
            let canonicalSource = canonicalFileURL(URL(fileURLWithPath: source)).path
            return (canonicalSource, nil)
        }
        guard let volumeClient else {
            throw Abort(.notImplemented, reason: "Named volume mounts are not configured")
        }
        return (try await volumeClient.inspect(name: source).Mountpoint, source)
    }

    private static func ports(from host: CreateHostConfig?) -> [DockerRuntimePortBinding] {
        (host?.PortBindings ?? [:]).flatMap { key, bindings -> [DockerRuntimePortBinding] in
            let pieces = key.split(separator: "/", maxSplits: 1)
            guard let port = Int(pieces[0]) else { return [] }
            let proto = pieces.count == 2 ? String(pieces[1]) : "tcp"
            return bindings.map {
                DockerRuntimePortBinding(
                    containerPort: port,
                    proto: proto,
                    hostIP: $0.HostIp ?? "0.0.0.0",
                    hostPort: $0.HostPort.flatMap(Int.init)
                )
            }
        }
    }
}

private struct ImageDeleteItem: Encodable {
    let Deleted: String?
    let Untagged: String?
}

private struct ImagePruneResponse: Encodable {
    let ImagesDeleted: [ImageDeleteItem]
    let SpaceReclaimed: Int64
}

private struct ImageSummary: Encodable {
    let Id: String
    let ParentId = ""
    let RepoTags: [String]
    let RepoDigests: [String]
    let Created: Int64
    let Size: Int64
    let SharedSize: Int64 = -1
    let VirtualSize: Int64
    let Labels: [String: String]
    let Containers: Int64 = -1

    init(_ image: DockerRuntimeImage) {
        Id = image.digest
        RepoTags = image.references.filter { !$0.contains("@sha256:") }
        RepoDigests = image.references.filter { $0.contains("@sha256:") }
        Created = Int64(image.createdAt.timeIntervalSince1970)
        Size = image.size
        VirtualSize = image.size
        Labels = image.labels
    }
}

private struct ImageInspectResponse: Encodable {
    struct ConfigPayload: Encodable {
        let Labels: [String: String]
    }
    struct RootFSPayload: Encodable {
        let `Type` = "layers"
        let Layers: [String]
    }

    let Id: String
    let RepoTags: [String]
    let RepoDigests: [String]
    let Created: String
    let Size: Int64
    let VirtualSize: Int64
    let Config: ConfigPayload
    let RootFS: RootFSPayload

    init(_ image: DockerRuntimeImage) {
        Id = image.digest
        RepoTags = image.references.filter { !$0.contains("@sha256:") }
        RepoDigests = image.references.filter { $0.contains("@sha256:") }
        Created = ISO8601DateFormatter().string(from: image.createdAt)
        Size = image.size
        VirtualSize = image.size
        Config = ConfigPayload(Labels: image.labels)
        RootFS = RootFSPayload(Layers: image.rootFSLayers)
    }
}

private struct CreateRequest: Content {
    let Image: String
    let Cmd: [String]?
    let Entrypoint: [String]?
    let Env: [String]?
    let WorkingDir: String?
    let User: String?
    let Hostname: String?
    let Labels: [String: String]?
    let Tty: Bool?
    let HostConfig: CreateHostConfig?
}

private struct CreateHostConfig: Content {
    let AutoRemove: Bool?
    let Binds: [String]?
    let Mounts: [CreateMount]?
    let PortBindings: [String: [CreatePortBinding]]?
}

private struct CreateMount: Content {
    let `Type`: String
    let Source: String?
    let Target: String
    let ReadOnly: Bool?
}

private struct CreatePortBinding: Content {
    let HostIp: String?
    let HostPort: String?
}

private struct ExecCreateRequest: Content {
    let Cmd: [String]?
    let AttachStdout: Bool?
    let AttachStderr: Bool?
    let Tty: Bool?
    let Env: [String]?
    let User: String?
    let WorkingDir: String?
}

private struct ExecStartRequest: Content {
    let Detach: Bool?
    let Tty: Bool?
}

private struct InspectResponse: Content {
    struct StatePayload: Content {
        let Status: String
        let Running: Bool
        let ExitCode: Int32
    }
    struct ConfigPayload: Content {
        let Image: String
        let Cmd: [String]
        let Tty: Bool
        let Labels: [String: String]
    }
    struct NetworkSettingsPayload: Content { let Ports: [String: [CreatePortBinding]] }
    struct HostConfigPayload: Content { let PortBindings: [String: [CreatePortBinding]] }

    let Id: String
    let Name: String
    let Image: String
    let Created: String
    let State: StatePayload
    let Config: ConfigPayload
    let HostConfig: HostConfigPayload
    let NetworkSettings: NetworkSettingsPayload

    init(_ container: DockerRuntimeContainer) {
        Id = container.id
        Name = container.name.hasPrefix("/") ? container.name : "/\(container.name)"
        Image = container.image
        Created = ISO8601DateFormatter().string(from: container.createdAt)
        State = .init(
            Status: container.state.rawValue,
            Running: container.state == .running,
            ExitCode: container.exitCode ?? 0
        )
        Config = .init(Image: container.image, Cmd: container.command, Tty: container.tty, Labels: container.labels)
        var ports: [String: [CreatePortBinding]] = [:]
        for binding in container.ports {
            ports["\(binding.containerPort)/\(binding.proto)", default: []].append(
                .init(HostIp: binding.hostIP, HostPort: binding.hostPort.map(String.init))
            )
        }
        HostConfig = .init(PortBindings: ports)
        NetworkSettings = .init(Ports: ports)
    }
}

private struct ListResponse: Content {
    struct PortPayload: Content {
        let IP: String
        let PrivatePort: Int
        let PublicPort: Int?
        let `Type`: String
    }
    let Id: String
    let Names: [String]
    let Image: String
    let Command: String
    let Created: Int64
    let Labels: [String: String]
    let State: String
    let Status: String
    let Ports: [PortPayload]

    init(_ container: DockerRuntimeContainer) {
        Id = container.id
        Names = [container.name.hasPrefix("/") ? container.name : "/\(container.name)"]
        Image = container.image
        Command = container.command.joined(separator: " ")
        Created = Int64(container.createdAt.timeIntervalSince1970)
        Labels = container.labels
        State = container.state.rawValue
        Status = container.state.rawValue
        Ports = container.ports.map {
            PortPayload(
                IP: $0.hostIP,
                PrivatePort: $0.containerPort,
                PublicPort: $0.hostPort,
                Type: $0.proto
            )
        }
    }
}

private struct ExecInspectResponse: Content {
    struct ProcessConfigPayload: Content {
        let entrypoint: String
        let arguments: [String]
        let tty: Bool
    }
    let ID: String
    let Running: Bool
    let ExitCode: Int32?
    let ContainerID: String
    let ProcessConfig: ProcessConfigPayload

    init(id: String, entry: DockerRuntimeExecState.Entry) {
        ID = id
        Running = entry.running
        ExitCode = entry.exitCode
        ContainerID = entry.request.containerID
        ProcessConfig = .init(
            entrypoint: entry.request.command.first ?? "",
            arguments: Array(entry.request.command.dropFirst()),
            tty: entry.request.tty
        )
    }
}
