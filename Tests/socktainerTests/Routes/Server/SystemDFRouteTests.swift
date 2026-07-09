import ContainerAPIClient
import ContainerBuild
import ContainerResource
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private struct EmptyImageClient: ClientImageProtocol {
    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult { fatalError("not exercised by this test") }
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
        ([], 0)
    }
    func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] { [] }
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        URL(fileURLWithPath: "/dev/null")
    }
}

private struct EmptyVolumeClient: ClientVolumeProtocol {
    func create(request: RESTVolumeCreate) async throws -> Volume { fatalError("not exercised by this test") }
    func delete(name: String) async throws {}
    func list(filters: String?, logger: Logger) async throws -> [Volume] { [] }
    func inspect(name: String) async throws -> Volume { fatalError("not exercised by this test") }
}

private struct EmptyBuilderClient: ClientBuilderProtocol {
    func ensureReachable(timeout: Duration, retryInterval: Duration, logger: Logger) async throws {}
    func connect(timeout: Duration, retryInterval: Duration, logger: Logger) async throws -> Builder {
        fatalError("not exercised when the default (includeAll) query builds an empty BuildCache")
    }
    func prune(_ request: BuilderPruneRequest, logger: Logger) async throws -> BuilderPruneResult {
        fatalError("not exercised by this test")
    }
    func diskUsage(logger: Logger) async throws -> [BuilderCacheRecord] {
        fatalError("not exercised when the default (includeAll) query builds an empty BuildCache")
    }
}

private struct FixedDiskUsageProvider: ContainerDiskUsageProviding {
    func diskUsage(id: String) async throws -> UInt64 { 0 }
}

@Suite("SystemDFRoute — container network settings")
struct SystemDFRouteNetworkSettingsTests {

    private func withRoute(
        container: ContainerSnapshot,
        test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)

            try app.register(
                collection: SystemDFRoute(
                    imageClient: EmptyImageClient(),
                    containerClient: StaticSnapshotClientMock(snapshot: container),
                    volumeClient: EmptyVolumeClient(),
                    builderClient: EmptyBuilderClient(),
                    diskUsageProvider: FixedDiskUsageProvider()
                ))
            try await test(app)
        }
    }

    @Test("Duplicate live network names do not crash /system/df")
    func duplicateLiveNetworkNamesDoNotCrash() async throws {
        let container = try makeContainerSnapshot(
            nativeId: "c1",
            networks: [(network: "dup", ip: "192.168.64.5"), (network: "dup", ip: "192.168.64.5")],
            labels: [:],
            status: .running
        )
        try await withRoute(container: container) { app in
            try await app.testing().test(.GET, "/system/df") { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(SystemDFResponse.self)
                #expect(body.Containers?.first?.NetworkSettings.Networks?.keys.contains("dup") == true)
            }
        }
    }
}
