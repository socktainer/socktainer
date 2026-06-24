import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

// MARK: - Mocks

private struct DummyError: Error {}

private struct ThrowingContainerClient: ClientContainerProtocol {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        throw DummyError()
    }
    func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

private struct EmptyContainerClient: ClientContainerProtocol {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

private struct StubImageClient: ClientImageProtocol {
    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult { ImageDeletionResult(untagged: id, digest: "sha256:abc", deletedDigest: nil) }
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func prune(filters: [String: [String]], logger: Logger) async throws -> (deletedImages: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
    func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] { [] }
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        URL(fileURLWithPath: "/dev/null")
    }
}

// MARK: - loadSystemConfig

@Suite("InfoRoute.loadSystemConfig")
struct InfoRouteLoadSystemConfigTests {
    private let logger = Logger(label: "test")

    @Test("Returns the loaded config on success")
    func returnsLoadedConfig() async throws {
        let loaded = ContainerSystemConfig(registry: .init(domain: "ghcr.io"))
        let config = try await InfoRoute.loadSystemConfig(using: { loaded }, logger: logger)
        #expect(config.registry.domain == "ghcr.io")
    }

    @Test("Falls back to defaults when loading fails")
    func fallsBackOnError() async throws {
        let config = try await InfoRoute.loadSystemConfig(using: { throw DummyError() }, logger: logger)
        #expect(config.registry.domain == ContainerSystemConfig().registry.domain)
    }

    @Test("Rethrows CancellationError instead of swallowing it")
    func rethrowsCancellation() async throws {
        await #expect(throws: CancellationError.self) {
            try await InfoRoute.loadSystemConfig(using: { throw CancellationError() }, logger: logger)
        }
    }
}

// MARK: - Route error path

@Suite("InfoRoute GET /info error handling")
struct InfoRouteErrorPathTests {

    private func withRoute(_ test: @escaping (Application) async throws -> Void) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(
                collection: InfoRoute(
                    containerClient: ThrowingContainerClient(),
                    imageClient: StubImageClient(),
                    configLoader: { ContainerSystemConfig() }
                ))
            try await test(app)
        }
    }

    @Test("Returns 500 with the documented JSON body when a dependency throws")
    func returns500OnFailure() async throws {
        try await withRoute { app in
            try await app.testing().test(.GET, "/info") { res async in
                #expect(res.status == .internalServerError)
                #expect(res.headers.first(name: .contentType) == "application/json")
                #expect(res.body.string == "{\"message\": \"Failed to generate system information\"}\n")
            }
        }
    }
}

// MARK: - Route label wiring

private struct InfoResponseBody: Decodable {
    let Labels: [String]
}

@Suite("InfoRoute GET /info label wiring")
struct InfoRouteLabelWiringTests {

    private func withRoute(
        configLoader: @escaping @Sendable () async throws -> ContainerSystemConfig,
        test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(
                collection: InfoRoute(
                    containerClient: EmptyContainerClient(),
                    imageClient: StubImageClient(),
                    configLoader: configLoader,
                    systemHealthProvider: { (dockerRootDir: "/tmp/app-root", serverVersion: "9.9.9") },
                    kernelNameProvider: { "vmlinux-test" }
                ))
            try await test(app)
        }
    }

    @Test("Response body includes all 8 system property labels with configured values")
    func bodyIncludesConfiguredLabels() async throws {
        let config = ContainerSystemConfig(dns: .init(domain: "test.local"), registry: .init(domain: "ghcr.io"))
        try await withRoute(configLoader: { config }) { app in
            try await app.testing().test(.GET, "/info") { res async in
                #expect(res.status == .ok)
                let labels = (try? JSONDecoder().decode(InfoResponseBody.self, from: res.body))?.Labels ?? []
                let keys = Set(labels.map { $0.components(separatedBy: "=").first ?? "" })
                #expect(
                    keys == [
                        "build.rosetta", "dns.domain", "image.builder", "image.init",
                        "kernel.binaryPath", "kernel.url", "network.subnet", "registry.domain",
                    ])
                #expect(labels.contains("dns.domain=test.local"))
                #expect(labels.contains("registry.domain=ghcr.io"))
            }
        }
    }

    @Test("Labels fall back to defaults when config loading fails")
    func bodyFallsBackWhenConfigFails() async throws {
        try await withRoute(configLoader: { throw DummyError() }) { app in
            try await app.testing().test(.GET, "/info") { res async in
                #expect(res.status == .ok)
                let labels = (try? JSONDecoder().decode(InfoResponseBody.self, from: res.body))?.Labels ?? []
                #expect(labels == InfoRoute.systemPropertyLabels(config: ContainerSystemConfig()))
            }
        }
    }
}
