import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression tests for a moby-conformance gap found while auditing issue #258: moby tears
/// down a container's network sandbox (and its DNS resolution) on every exit via
/// `daemon.Cleanup`, not just `--rm`. Socktainer previously only unregistered DNS aliases on
/// `--rm` auto-remove or explicit delete, so a plain `docker stop` left a stale, resolvable
/// DNS entry pointing at a dead container's IP indefinitely.
@Suite("ContainerStartRoute — DNS cleanup on a terminal (non-restarting) stop")
struct ContainerStartRouteStopDNSCleanupTests {

    @Test("a container with no restart policy unregisters its DNS alias on exit")
    func plainStopUnregistersDNS() async throws {
        let nativeId = "stop-dns-plain-ctr"
        let ip = "192.168.65.90"
        let network = "myapp_default"

        let snapshot = try makeContainerSnapshot(nativeId: nativeId, ip: ip, network: network, labels: [:])
        let mock = StaticSnapshotClientMock(snapshot: snapshot)
        let dnsServer = SocktainerDNSServer()

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

        await ContainerExitCodeStore.shared.set(id: nativeId, code: 0)

        let cleaned = try await pollUntil(timeoutSeconds: 2) {
            dnsServer.listEntries()[nativeId] == nil
        }
        #expect(cleaned, "a container with no restart policy must unregister its DNS alias once it exits")

        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }

    @Test("on-failure declining to restart on a clean exit unregisters its DNS alias")
    func onFailureDecliningToRestartUnregistersDNS() async throws {
        let nativeId = "stop-dns-on-failure-ctr"
        let ip = "192.168.65.91"
        let network = "myapp_default"

        let policy = RestartPolicy(Name: "on-failure", MaximumRetryCount: nil)
        let policyJSON = String(data: try JSONEncoder().encode(policy), encoding: .utf8)!
        let snapshot = try makeContainerSnapshot(
            nativeId: nativeId, ip: ip, network: network,
            labels: [RestartPolicyManager.label: policyJSON]
        )
        let mock = StaticSnapshotClientMock(snapshot: snapshot)
        let dnsServer = SocktainerDNSServer()

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

        // on-failure never restarts on a clean (code 0) exit.
        await ContainerExitCodeStore.shared.set(id: nativeId, code: 0)

        let cleaned = try await pollUntil(timeoutSeconds: 2) {
            dnsServer.listEntries()[nativeId] == nil
        }
        #expect(cleaned, "on-failure declining to restart on a clean exit must unregister its DNS alias")

        await ContainerRestartState.shared.reset(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: nativeId)
    }
}
