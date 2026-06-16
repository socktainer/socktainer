import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("Compose DNS — service name registration")
struct ComposeDNSTests {

    // MARK: - Start route registers compose DNS aliases

    @Test("Start registers service and service.project aliases when compose labels present")
    func startRegistersComposeDNSAliases() async throws {
        let nativeId = "compose-db-container"
        let ip = "192.168.65.20"
        let snapshot = try makeSnapshot(
            nativeId: nativeId, ip: ip,
            labels: [
                "com.docker.compose.service": "db",
                "com.docker.compose.project": "myapp",
            ])
        let dnsServer = SocktainerDNSServer()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[SocktainerDNSServerKey.self] = dnsServer
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStartRoute(client: ComposeMock(snapshot: snapshot)))

            try await app.testing().test(.POST, "/v1.51/containers/abc123/start") { res async in
                #expect(res.status == .noContent)
            }
        }

        let entries = dnsServer.listEntries()
        #expect(entries["db"] == ip, "short service name must be registered with correct IP")
        #expect(entries["db.myapp"] == ip, "qualified service.project alias must be registered")
    }

    @Test("Start registers only service alias when project label is absent")
    func startRegistersServiceOnlyWithoutProject() async throws {
        let snapshot = try makeSnapshot(
            nativeId: "compose-cache", ip: "192.168.65.21",
            labels: ["com.docker.compose.service": "cache"])
        let dnsServer = SocktainerDNSServer()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[SocktainerDNSServerKey.self] = dnsServer
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStartRoute(client: ComposeMock(snapshot: snapshot)))

            try await app.testing().test(.POST, "/v1.51/containers/abc456/start") { _ async in }
        }

        let entries = dnsServer.listEntries()
        #expect(entries["cache"] != nil, "short service name must be registered")
        #expect(
            entries.keys.filter { $0.hasPrefix("cache.") }.isEmpty,
            "no qualified alias without project label")
    }

    @Test("Start does not register compose DNS for non-compose containers")
    func startSkipsComposeDNSWithoutLabels() async throws {
        let snapshot = try makeSnapshot(nativeId: "plain-container", ip: "192.168.65.22", labels: [:])
        let dnsServer = SocktainerDNSServer()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[SocktainerDNSServerKey.self] = dnsServer
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStartRoute(client: ComposeMock(snapshot: snapshot)))

            try await app.testing().test(.POST, "/v1.51/containers/abc789/start") { _ async in }
        }

        #expect(dnsServer.listEntries().isEmpty, "no DNS entries for non-compose container")
    }

    // MARK: - Delete route unregisters compose DNS aliases

    @Test("Delete unregisters both service and service.project aliases")
    func deleteUnregistersComposeDNSAliases() async throws {
        let snapshot = try makeSnapshot(
            nativeId: "compose-web", ip: "192.168.65.30",
            labels: [
                "com.docker.compose.service": "web",
                "com.docker.compose.project": "shop",
            ])
        let dnsServer = SocktainerDNSServer()
        dnsServer.register(hostname: "web", ip: "192.168.65.30")
        dnsServer.register(hostname: "web.shop", ip: "192.168.65.30")
        #expect(dnsServer.listEntries()["web"] != nil)
        #expect(dnsServer.listEntries()["web.shop"] != nil)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[SocktainerDNSServerKey.self] = dnsServer
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerDeleteRoute(client: ComposeMock(snapshot: snapshot)))

            try await app.testing().test(.DELETE, "/v1.51/containers/abc000") { res async in
                #expect(res.status == .ok)
            }
        }

        #expect(dnsServer.listEntries()["web"] == nil, "service alias must be unregistered on delete")
        #expect(dnsServer.listEntries()["web.shop"] == nil, "qualified alias must be unregistered on delete")
    }

    @Test("Delete preserves alias when another container has taken ownership")
    func deletePreservesAliasOwnedByAnotherContainer() async throws {
        let snapshot = try makeSnapshot(
            nativeId: "compose-web-old", ip: "192.168.65.30",
            labels: [
                "com.docker.compose.service": "web",
                "com.docker.compose.project": "shop",
            ])
        let dnsServer = SocktainerDNSServer()
        // Simulate a second container claiming the same aliases before the first is deleted
        dnsServer.register(hostname: "web", ip: "192.168.65.31")
        dnsServer.register(hostname: "web.shop", ip: "192.168.65.31")

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[SocktainerDNSServerKey.self] = dnsServer
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerDeleteRoute(client: ComposeMock(snapshot: snapshot)))

            try await app.testing().test(.DELETE, "/v1.51/containers/abc001") { res async in
                #expect(res.status == .ok)
            }
        }

        let entries = dnsServer.listEntries()
        #expect(entries["web"] == "192.168.65.31", "alias owned by another container must be preserved")
        #expect(entries["web.shop"] == "192.168.65.31", "qualified alias owned by another container must be preserved")
    }

    // MARK: - Network connect/disconnect return 200

    @Test("POST /networks/{id}/connect returns 200")
    func networkConnectReturns200() async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: NetworkConnectRoute())

            try await app.testing().test(.POST, "/v1.51/networks/myapp_default/connect") { res async in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("POST /networks/{id}/disconnect returns 200")
    func networkDisconnectReturns200() async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: NetworkDisconnectRoute())

            try await app.testing().test(.POST, "/v1.51/networks/myapp_default/disconnect") { res async in
                #expect(res.status == .ok)
            }
        }
    }
}

// MARK: - Helpers

/// Constructs a ContainerSnapshot with a real Attachment (decoded from JSON) so that
/// DNS registration code can extract the IP from networks.first.ipv4Address.
private func makeSnapshot(nativeId: String, ip: String, labels: [String: String]) throws -> ContainerSnapshot {
    let proc = ProcessConfiguration(
        executable: "/bin/sh", arguments: [], environment: [],
        workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
    )
    let img = ImageDescription(
        reference: "alpine:latest",
        descriptor: Descriptor(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest: "sha256:abc", size: 0
        )
    )
    var config = ContainerConfiguration(id: nativeId, image: img, process: proc)
    config.labels = labels

    // Attachment is Codable — use JSON to avoid depending on internal CIDRv4/IPv4Address inits.
    // CIDRv4 and IPv4Address are single-value string types: "192.168.x.x/24" and "192.168.x.x".
    let attachmentJSON = """
        {
            "network": "default",
            "hostname": "\(nativeId)",
            "ipv4Address": "\(ip)/24",
            "ipv4Gateway": "192.168.65.1",
            "ipv6Address": null,
            "macAddress": null
        }
        """.data(using: .utf8)!
    let attachment = try JSONDecoder().decode(Attachment.self, from: attachmentJSON)

    return ContainerSnapshot(configuration: config, status: .stopped, networks: [attachment])
}

private struct ComposeMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
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
