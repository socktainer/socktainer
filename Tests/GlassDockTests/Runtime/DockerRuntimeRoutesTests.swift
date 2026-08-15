import Foundation
import NIOCore
import Testing
import Vapor
import VaporTesting

@testable import GlassDock

@Suite("Docker runtime v1.51 routes")
struct DockerRuntimeRoutesTests {
    @Test("restored port bindings default an omitted host IP")
    func restoredPortBindingDefaultsHostIP() throws {
        let binding = try JSONDecoder().decode(
            DockerRuntimePortBinding.self,
            from: Data(#"{"containerPort":80,"protocol":"tcp"}"#.utf8)
        )

        #expect(binding.hostIP == "0.0.0.0")
        #expect(binding.hostPort == nil)
    }

    @Test("image pull forwards a pinned reference and platform")
    func pullImage() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/images/create?fromImage=example.test%2Ffixture&tag=sha256-deadbeef&platform=linux%2Farm64"
            ) { response async in
                #expect(response.status == .ok)
                #expect(response.headers.contentType == .json)
                #expect(response.body.string.contains("Downloaded newer image"))
                #expect(response.body.string.hasSuffix("\n"))
            }
        }
        let pull = await backend.lastPull
        #expect(pull?.reference == "example.test/fixture:sha256-deadbeef")
        #expect(pull?.platform == "linux/arm64")
    }

    @Test("containerd image lifecycle uses Docker response shapes")
    func imageLifecycle() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(.GET, "/v1.51/images/json") { response async throws in
                #expect(response.status == .ok)
                let rows = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(rows?.first?["Id"] as? String == "sha256:abc")
                #expect(rows?.first?["RepoTags"] as? [String] == ["example.test/fixture:latest"])
            }
            try await app.testing().test(.GET, "/v1.51/images/example.test%2Ffixture:latest/json") { response async throws in
                #expect(response.status == .ok)
                let image = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(image?["Id"] as? String == "sha256:abc")
                #expect((image?["RootFS"] as? [String: Any])?["Type"] as? String == "layers")
            }
            try await app.testing().test(
                .POST,
                "/v1.51/images/example.test%2Ffixture:latest/tag?repo=example.test%2Fcopy&tag=v1"
            ) { response async in
                #expect(response.status == .created)
            }
            try await app.testing().test(.DELETE, "/v1.51/images/example.test%2Ffixture:latest?force=1") { response async throws in
                #expect(response.status == .ok)
                let items = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(items?.contains { $0["Deleted"] as? String == "sha256:abc" } == true)
            }
            let filters = "%7B%22dangling%22:%7B%22false%22:true%7D%7D"
            try await app.testing().test(.POST, "/v1.51/images/prune?filters=\(filters)") { response async throws in
                #expect(response.status == .ok)
                let result = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(result?["SpaceReclaimed"] as? Int == 12)
            }
        }
        #expect(await backend.lastImageDeleteForce == true)
        #expect(await backend.lastTagTarget == "example.test/copy:v1")
        #expect(await backend.lastPruneAll == true)
    }

    @Test("container lifecycle maps Docker create fields and status codes")
    func containerLifecycle() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            let createBody = #"""
                {
                  "Image":"fixture@sha256:abc",
                  "Cmd":["/bin/true"],
                  "Env":["A=B"],
                  "WorkingDir":"/work",
                  "Labels":{"test":"true"},
                  "HostConfig":{
                    "AutoRemove":true,
                    "Binds":["/tmp/source:/data:ro"],
                    "PortBindings":{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":"18080"}]}
                  }
                }
                """#
            try await app.testing().test(
                .POST,
                "/v1.51/containers/create?name=bench",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: createBody)
            ) { response async throws in
                #expect(response.status == .created)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(value?["Id"] as? String == "container-1")
            }

            try await app.testing().test(.POST, "/v1.51/containers/container-1/start") { response async in
                #expect(response.status == .noContent)
            }
            try await app.testing().test(.POST, "/v1.51/containers/container-1/wait?condition=next-exit") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(value?["StatusCode"] as? Int == 7)
            }
            try await app.testing().test(.GET, "/v1.51/containers/container-1/json") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                let state = value?["State"] as? [String: Any]
                #expect(state?["Running"] as? Bool == true)
                let hostConfig = value?["HostConfig"] as? [String: Any]
                let portBindings = hostConfig?["PortBindings"] as? [String: Any]
                #expect(portBindings?["80/tcp"] != nil)
            }
            try await app.testing().test(.GET, "/v1.51/containers/json?all=1") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(value?.first?["Id"] as? String == "container-1")
                let ports = value?.first?["Ports"] as? [[String: Any]]
                #expect(ports?.first?["PublicPort"] as? Int == 18080)
            }
            try await app.testing().test(.DELETE, "/v1.51/containers/container-1?force=1&v=true") { response async in
                #expect(response.status == .noContent)
            }
        }

        let create = try #require(await backend.lastCreate)
        #expect(create.name == "bench")
        #expect(create.command == ["/bin/true"])
        #expect(create.environment == ["A=B"])
        #expect(create.autoRemove)
        #expect(create.mounts == [.init(source: "/private/tmp/source", target: "/data", readOnly: true)])
        #expect(create.ports == [.init(containerPort: 80, proto: "tcp", hostIP: "127.0.0.1", hostPort: 18080)])
        #expect(await backend.lastWaitCondition == .nextExit)
        #expect(await backend.lastListShowAll == true)
        #expect(await backend.lastDelete == .init(force: true, volumes: true))
    }

    @Test("container create canonicalizes macOS bind path aliases")
    func containerCreateCanonicalizesBindPathAliases() async throws {
        let backend = DockerRuntimeBackendMock()
        let canonicalSource = "/private/var/tmp/glassdock-bind-\(UUID().uuidString)"
        let aliasedSource = String(canonicalSource.dropFirst("/private".count))
        try FileManager.default.createDirectory(
            atPath: canonicalSource,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(atPath: canonicalSource) }

        try await withRuntimeRoutes(backend) { app in
            let body = #"{"Image":"fixture@sha256:abc","HostConfig":{"Binds":["\#(aliasedSource):/data"]}}"#
            try await app.testing().test(
                .POST,
                "/v1.51/containers/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: body)
            ) { response async in
                #expect(response.status == .created)
            }
        }

        let create = try #require(await backend.lastCreate)
        #expect(create.mounts == [.init(source: canonicalSource, target: "/data", readOnly: false)])
    }

    @Test("exec start returns stdcopy frames and records the exit code")
    func execLifecycle() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/containers/container-1/exec",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Cmd":["printf","hello"],"AttachStdout":true}"#)
            ) { response async throws in
                #expect(response.status == .created)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(value?["Id"] as? String == "exec-1")
            }
            try await app.testing().test(
                .POST,
                "/v1.51/exec/exec-1/start",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Detach":false,"Tty":false}"#)
            ) { response async in
                #expect(response.status == .ok)
                let bytes = Array(response.body.readableBytesView)
                #expect(Array(bytes.prefix(8)) == [1, 0, 0, 0, 0, 0, 0, 5])
                #expect(String(decoding: bytes.dropFirst(8), as: UTF8.self) == "hello")
            }
            try await app.testing().test(.GET, "/v1.51/exec/exec-1/json") { response async throws in
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(value?["Running"] as? Bool == false)
                #expect(value?["ExitCode"] as? Int == 23)
            }
        }
        #expect(await backend.lastExec?.command == ["printf", "hello"])
    }

    @Test("logs use Docker framing and backend not-found maps to 404")
    func logsAndErrors() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(.GET, "/v1.51/containers/container-1/logs?stdout=1&stderr=1") { response async in
                #expect(response.status == .ok)
                let bytes = Array(response.body.readableBytesView)
                #expect(bytes[0] == 1)
                #expect(bytes[11] == 2)
            }
            try await app.testing().test(.GET, "/v1.51/containers/missing/json") { response async in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("container list applies exact label filters")
    func listLabelFilters() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            let matching = "%7B%22label%22:%5B%22test%3Dtrue%22%5D%7D"
            try await app.testing().test(.GET, "/v1.51/containers/json?all=1&filters=\(matching)") { response async throws in
                let values = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(values?.count == 1)
            }
            let different = "%7B%22label%22:%5B%22glassdock.benchmark.run%3Dother%22%5D%7D"
            try await app.testing().test(.GET, "/v1.51/containers/json?all=1&filters=\(different)") { response async throws in
                let values = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(values?.isEmpty == true)
            }
        }
    }

    @Test("known unsupported routes return explicit 501 errors")
    func explicitUnsupportedRoutes() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withApp(configure: { _ in }) { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            router.installMiddleware(on: app)
            try app.register(collection: DockerRuntimeRoutes(backend: backend))
            try app.register(collection: ExplicitUnsupportedDockerRoutes())
            try await app.testing().test(.GET, "/v1.51/info") { response async in
                #expect(response.status == .notImplemented)
                #expect(response.body.string.contains("not implemented"))
            }
            try await app.testing().test(.POST, "/v1.51/containers/container-1/restart") { response async in
                #expect(response.status == .notImplemented)
            }
            try await app.testing().test(.HEAD, "/v1.51/containers/container-1/archive") { response async in
                #expect(response.status == .notImplemented)
            }
            try await app.testing().test(.GET, "/v1.51/containers/container-1/attach/ws") { response async in
                #expect(response.status == .notImplemented)
            }
        }
    }

    @Test("unsupported create options fail explicitly")
    func unsupportedCreateOptions() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            for body in [
                #"{"Image":"fixture","HostConfig":{"Privileged":true}}"#,
                #"{"Image":"fixture","HostConfig":{"Memory":1048576}}"#,
                #"{"Image":"fixture","HostConfig":{"RestartPolicy":{"Name":"always"}}}"#,
                #"{"Image":"fixture","HostConfig":{"NetworkMode":"host"}}"#,
                #"{"Image":"fixture","OpenStdin":true}"#,
            ] {
                try await app.testing().test(
                    .POST, "/v1.51/containers/create",
                    headers: ["Content-Type": "application/json"], body: ByteBuffer(string: body)
                ) { response async in
                    #expect(response.status == .notImplemented)
                }
            }
            try await app.testing().test(
                .POST, "/v1.51/containers/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(
                    string: #"{"Image":"fixture","HostConfig":{"Privileged":false,"Memory":0,"NetworkMode":"default"}}"#)
            ) { response async in
                #expect(response.status == .created)
            }
        }
    }

    @Test("image import fails explicitly")
    func unsupportedImageImport() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(.POST, "/v1.51/images/create?fromSrc=-") { response async in
                #expect(response.status == .notImplemented)
            }
        }
    }

    @Test("attach upgrades without starting a created container")
    func attachDoesNotStartContainer() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/containers/container-1/attach?stream=1&stdout=1&stderr=1",
                headers: ["Connection": "Upgrade", "Upgrade": "tcp"]
            ) { response async in
                #expect(response.status == .switchingProtocols)
                #expect(response.headers.first(name: "Upgrade") == "tcp")
                let bytes = Array(response.body.readableBytesView)
                #expect(Array(bytes.prefix(8)) == [1, 0, 0, 0, 0, 0, 0, 3])
            }
        }
        #expect(await backend.startCount == 0)
    }
}

private func withRuntimeRoutes(
    _ backend: DockerRuntimeBackendMock,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let router = app.regexRouter(with: app.logger)
        app.setRegexRouter(router)
        router.installMiddleware(on: app)
        try app.register(collection: DockerRuntimeRoutes(backend: backend))
        try await test(app)
    }
}

private actor DockerRuntimeBackendMock: DockerRuntimeRouteBackend {
    struct Pull: Equatable {
        let reference: String
        let platform: String?
    }
    struct Delete: Equatable {
        let force: Bool
        let volumes: Bool
    }

    private(set) var lastPull: Pull?
    private(set) var lastCreate: DockerRuntimeContainerCreate?
    private(set) var lastWaitCondition: ContainerWaitCondition?
    private(set) var lastListShowAll: Bool?
    private(set) var lastDelete: Delete?
    private(set) var lastExec: DockerRuntimeExecCreate?
    private(set) var lastImageDeleteForce: Bool?
    private(set) var lastTagTarget: String?
    private(set) var lastPruneAll: Bool?
    private(set) var startCount = 0
    private var running = false

    func pullImage(
        reference: String, platform: String?, auth: DockerRegistryAuth?
    ) async throws -> DockerRuntimeImage {
        lastPull = Pull(reference: reference, platform: platform)
        return DockerRuntimeImage(reference: reference, digest: "sha256:abc")
    }

    func listImages() async throws -> [DockerRuntimeImage] {
        [DockerRuntimeImage(reference: "example.test/fixture:latest", digest: "sha256:abc")]
    }

    func inspectImage(reference: String) async throws -> DockerRuntimeImage {
        guard reference != "missing" else { throw DockerRuntimeRouteError.notFound("No such image: missing") }
        return DockerRuntimeImage(reference: reference, digest: "sha256:abc")
    }

    func deleteImage(reference: String, force: Bool) async throws -> DockerRuntimeImageDelete {
        lastImageDeleteForce = force
        return DockerRuntimeImageDelete(deleted: ["sha256:abc"], untagged: [reference], reclaimed: 12)
    }

    func pruneImages(all: Bool) async throws -> DockerRuntimeImageDelete {
        lastPruneAll = all
        return DockerRuntimeImageDelete(deleted: all ? ["sha256:abc"] : [], untagged: [], reclaimed: all ? 12 : 0)
    }

    func tagImage(source: String, target: String) async throws { lastTagTarget = target }

    func createContainer(_ request: DockerRuntimeContainerCreate) async throws -> DockerRuntimeContainer {
        lastCreate = request
        return container()
    }

    func startContainer(id: String) async throws {
        startCount += 1
        running = true
    }

    func waitContainer(id: String, condition: ContainerWaitCondition) async throws -> Int32 {
        lastWaitCondition = condition
        return 7
    }

    func deleteContainer(id: String, force: Bool, removeVolumes: Bool) async throws {
        lastDelete = Delete(force: force, volumes: removeVolumes)
    }

    func inspectContainer(id: String) async throws -> DockerRuntimeContainer {
        guard id != "missing" else { throw DockerRuntimeRouteError.notFound("No such container: missing") }
        return container()
    }

    func listContainers(showAll: Bool) async throws -> [DockerRuntimeContainer] {
        lastListShowAll = showAll
        return [container()]
    }

    func createExec(_ request: DockerRuntimeExecCreate) async throws -> String {
        lastExec = request
        return "exec-1"
    }

    func startExec(id: String, detach: Bool, tty: Bool) async throws -> DockerRuntimeProcessOutput {
        DockerRuntimeProcessOutput(stdout: Data("hello".utf8), exitCode: 23)
    }

    func logs(id: String, stdout: Bool, stderr: Bool) async throws -> DockerRuntimeProcessOutput {
        DockerRuntimeProcessOutput(
            stdout: stdout ? Data("out".utf8) : Data(),
            stderr: stderr ? Data("err".utf8) : Data(),
            exitCode: 0
        )
    }

    private func container() -> DockerRuntimeContainer {
        DockerRuntimeContainer(
            id: "container-1",
            name: "bench",
            image: "fixture@sha256:abc",
            command: ["/bin/true"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: running ? .running : .created,
            exitCode: nil,
            labels: ["test": "true"],
            tty: false,
            ports: [.init(containerPort: 80, proto: "tcp", hostIP: "127.0.0.1", hostPort: 18080)]
        )
    }
}
