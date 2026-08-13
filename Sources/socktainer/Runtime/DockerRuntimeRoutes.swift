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
    func pullImage(reference: String, platform: String?) async throws -> DockerRuntimeImage
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
    func logs(id: String, stdout: Bool, stderr: Bool) async throws -> DockerRuntimeProcessOutput
    func containerAutoRemove(id: String) async throws -> Bool
}

extension DockerRuntimeRouteBackend {
    func containerAutoRemove(id: String) async throws -> Bool { false }
    func killContainer(id: String, signal: UInt32) async throws {
        throw DockerRuntimeRouteError.invalidRequest("container signals are not supported")
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
}

struct DockerRuntimeContainerCreate: Sendable, Equatable {
    let name: String?
    let image: String
    let command: [String]
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
    private let execState = DockerRuntimeExecState()

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
        let fromImage = try requiredQuery("fromImage", request: req)
        let tag = req.query[String.self, at: "tag"]
        let reference = Self.imageReference(fromImage: fromImage, tag: tag)
        let image = try await call { try await backend.pullImage(reference: reference, platform: req.query[String.self, at: "platform"]) }
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
            body = try JSONDecoder().decode(CreateRequest.self, from: data)
        } catch {
            throw Abort(.badRequest, reason: "Invalid container create request: \(error)")
        }
        guard !body.Image.isEmpty else { throw Abort(.badRequest, reason: "No image specified") }
        let mounts = try Self.mounts(from: body.HostConfig)
        let request = DockerRuntimeContainerCreate(
            name: req.query[String.self, at: "name"],
            image: body.Image,
            command: (body.Entrypoint ?? []) + (body.Cmd ?? []),
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
        let condition = raw.flatMap(ContainerWaitCondition.init(rawValue:)) ?? .default
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
        try await call { try await backend.killContainer(id: id, signal: 15) }
        return Response(status: .noContent)
    }

    private func killContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let signal = req.query[UInt32.self, at: "signal"] ?? 9
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
        return Response(status: .noContent)
    }

    private func inspectContainer(_ req: Request) async throws -> Response {
        let container = try await call { try await backend.inspectContainer(id: requiredParameter("id", request: req)) }
        return try jsonResponse(.ok, InspectResponse(container))
    }

    private func listContainers(_ req: Request) async throws -> Response {
        let containers = try await call {
            try await backend.listContainers(showAll: Self.mobyBool(req.query[String.self, at: "all"]))
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
        do {
            let output = try await call {
                try await backend.startExec(id: id, detach: body.Detach ?? false, tty: body.Tty ?? entry.request.tty)
            }
            await execState.finish(id: id, exitCode: output.exitCode)
            if body.Detach ?? false { return Response(status: .ok) }
            let response = Self.streamResponse(output: output, tty: body.Tty ?? entry.request.tty)
            if req.headers.first(name: "Upgrade")?.lowercased() == "tcp" {
                response.status = .switchingProtocols
                response.headers.replaceOrAdd(name: "Connection", value: "Upgrade")
                response.headers.replaceOrAdd(name: "Upgrade", value: "tcp")
            }
            return response
        } catch {
            await execState.finish(id: id, exitCode: -1)
            throw error
        }
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
        let container = try await call { try await backend.inspectContainer(id: id) }
        let backend = self.backend
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
                _ = try await backend.waitContainer(id: id, condition: .notRunning)
                let output = try await backend.logs(id: id, stdout: true, stderr: true)
                if try await backend.containerAutoRemove(id: id) {
                    // Complete deletion before any final output can let the
                    // Docker client report that an auto-remove run finished.
                    try await backend.deleteContainer(id: id, force: true, removeVolumes: true)
                }
                if container.tty {
                    try await writer.writeBuffer(ByteBuffer(data: output.stdout + output.stderr))
                } else {
                    try await writer.writeBuffer(
                        ByteBuffer(data: Self.frame(output.stdout, stream: 1))
                    )
                    try await writer.writeBuffer(
                        ByteBuffer(data: Self.frame(output.stderr, stream: 2))
                    )
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

    private static func imageDeleteItems(_ result: DockerRuntimeImageDelete) -> [ImageDeleteItem] {
        result.untagged.map { ImageDeleteItem(Deleted: nil, Untagged: $0) }
            + result.deleted.map { ImageDeleteItem(Deleted: $0, Untagged: nil) }
    }

    private static func mounts(from host: CreateHostConfig?) throws -> [DockerRuntimeMount] {
        var result: [DockerRuntimeMount] = []
        for bind in host?.Binds ?? [] {
            let components = bind.split(separator: ":", maxSplits: 2).map(String.init)
            guard components.count >= 2, components[0].hasPrefix("/"), components[1].hasPrefix("/") else {
                throw Abort(.badRequest, reason: "Invalid bind mount: \(bind)")
            }
            result.append(DockerRuntimeMount(source: components[0], target: components[1], readOnly: components.count == 3 && components[2].split(separator: ",").contains("ro")))
        }
        for mount in host?.Mounts ?? [] where mount.`Type` == "bind" {
            guard let source = mount.Source, source.hasPrefix("/"), mount.Target.hasPrefix("/") else {
                throw Abort(.badRequest, reason: "Invalid bind mount")
            }
            result.append(DockerRuntimeMount(source: source, target: mount.Target, readOnly: mount.ReadOnly ?? false))
        }
        return result
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
