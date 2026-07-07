import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression test for issue #258: `observeExit`'s `--rm` auto-remove cleanup only
/// unregistered a container's primary name, leaving its Compose service/project aliases
/// pointing at a deleted container's IP.
@Suite("ContainerStartRoute — --rm auto-remove DNS alias cleanup")
struct ContainerStartRouteAutoRemoveAliasTests {

    @Test("die on a --rm container unregisters its name and its compose service/project aliases")
    func autoRemoveUnregistersFullAliasSet() async throws {
        let nativeId = "web-autoremove-ctr"
        let ip = "192.168.65.80"
        let network = "myapp_default"

        let snapshot = try makeSnapshot(nativeId: nativeId, ip: ip, network: network)
        let mock = AutoRemoveMock(snapshot: snapshot)
        let dnsServer = SocktainerDNSServer()

        // Marked --rm at create time; ContainerStartRoute doesn't touch this cache entry itself.
        await ContainerInfoCache.shared.markAutoRemove(hexId: nativeId, nativeId: nativeId)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[SocktainerDNSServerKey.self] = dnsServer
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStartRoute(client: mock))

            try await app.testing().test(.POST, "/v1.51/containers/\(nativeId)/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        #expect(dnsServer.listEntries()[nativeId] == ip)
        #expect(dnsServer.listEntries()["web"] == ip)
        #expect(dnsServer.listEntries()["web.myapp"] == ip)

        await ContainerExitCodeStore.shared.set(id: nativeId, code: 0)

        let cleaned = try await pollUntil(timeoutSeconds: 2) {
            dnsServer.listEntries()[nativeId] == nil
        }
        #expect(cleaned, "the container's own name must be unregistered on --rm exit")
        #expect(dnsServer.listEntries()["web"] == nil, "the compose service alias must also be unregistered")
        #expect(dnsServer.listEntries()["web.myapp"] == nil, "the compose project-qualified alias must also be unregistered")

        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }
}

private func makeSnapshot(nativeId: String, ip: String, network: String) throws -> ContainerSnapshot {
    try makeContainerSnapshot(
        nativeId: nativeId, ip: ip, network: network,
        labels: [
            "com.docker.compose.service": "web",
            "com.docker.compose.project": "myapp",
        ]
    )
}

private actor AutoRemoveMock: ClientContainerProtocol {
    private var snapshot: ContainerSnapshot

    init(snapshot: ContainerSnapshot) {
        self.snapshot = snapshot
    }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {
        await ContainerExitCodeStore.shared.remove(id: id)
    }
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
