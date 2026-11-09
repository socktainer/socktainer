import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("Network connect/disconnect — aliases")
struct NetworkConnectAliasesTests {

    private static let network = "myapp_default"

    @Test("Connect to a network the container is on registers EndpointConfig.Aliases")
    func connectRegistersAliases() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "connect-registers", ip: "192.168.65.40", network: Self.network, labels: [:], status: .running)
        let dnsServer = SocktainerDNSServer()

        try await withNetworkRoutes(client: StaticSnapshotClientMock(snapshot: snapshot), dnsServer: dnsServer) { app in
            try await connect(app, container: "connect-registers", aliases: ["first.example", "second.example"])
        }

        let entries = dnsServer.listEntries()
        #expect(entries["first.example"] == "192.168.65.40")
        #expect(entries["second.example"] == "192.168.65.40")
    }

    @Test("Reconnect replaces the aliases an earlier connect added")
    func reconnectReplacesAliases() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "connect-replaces", ip: "192.168.65.41", network: Self.network, labels: [:], status: .running)
        let dnsServer = SocktainerDNSServer()

        try await withNetworkRoutes(client: StaticSnapshotClientMock(snapshot: snapshot), dnsServer: dnsServer) { app in
            try await connect(app, container: "connect-replaces", aliases: ["old.example", "kept.example"])
            try await connect(app, container: "connect-replaces", aliases: ["kept.example", "new.example"])
        }

        let entries = dnsServer.listEntries()
        #expect(entries["old.example"] == nil)
        #expect(entries["kept.example"] == "192.168.65.41")
        #expect(entries["new.example"] == "192.168.65.41")
    }

    @Test("Disconnect then connect, as clients update aliases, leaves only the new list")
    func disconnectThenConnect() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "disconnect-connect", ip: "192.168.65.42", network: Self.network, labels: [:], status: .running)
        let dnsServer = SocktainerDNSServer()

        try await withNetworkRoutes(client: StaticSnapshotClientMock(snapshot: snapshot), dnsServer: dnsServer) { app in
            try await connect(app, container: "disconnect-connect", aliases: ["a.example"])
            try await app.testing().test(
                .POST, "/v1.51/networks/\(Self.network)/disconnect",
                beforeRequest: { req in try req.content.encode(["Container": "disconnect-connect"], as: .json) }
            ) { res async in
                #expect(res.status == .ok)
            }
            #expect(dnsServer.listEntries()["a.example"] == nil, "disconnect must drop the connected alias")
            try await connect(app, container: "disconnect-connect", aliases: ["a.example", "b.example"])
        }

        let entries = dnsServer.listEntries()
        #expect(entries["a.example"] == "192.168.65.42")
        #expect(entries["b.example"] == "192.168.65.42")
    }

    @Test("Connect to a network the container isn't on registers nothing")
    func connectOtherNetworkIsNoOp() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "connect-other", ip: "192.168.65.43", network: Self.network, labels: [:], status: .running)
        let dnsServer = SocktainerDNSServer()

        try await withNetworkRoutes(client: StaticSnapshotClientMock(snapshot: snapshot), dnsServer: dnsServer) { app in
            try await connect(app, container: "connect-other", aliases: ["elsewhere.example"], network: "other_net")
        }

        #expect(dnsServer.listEntries()["elsewhere.example"] == nil)
    }

    @Test("Connect for a container that doesn't exist answers 404")
    func connectMissingContainer() async throws {
        try await withNetworkRoutes(client: MissingContainerClient(), dnsServer: SocktainerDNSServer()) { app in
            try await app.testing().test(
                .POST, "/v1.51/networks/\(Self.network)/connect",
                beforeRequest: { req in try req.content.encode(["Container": "nope"], as: .json) }
            ) { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("Alias cleanup on stop or removal also drops connected aliases")
    func cleanupDropsConnectedAliases() async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "connect-cleanup", ip: "192.168.65.44", network: Self.network, labels: [:], status: .running)
        let dnsServer = SocktainerDNSServer()

        try await withNetworkRoutes(client: StaticSnapshotClientMock(snapshot: snapshot), dnsServer: dnsServer) { app in
            try await connect(app, container: "connect-cleanup", aliases: ["gone.example"])
        }
        ContainerAliasCleanup.unregisterAllAliases(
            nativeId: "connect-cleanup", labels: [:], cachedIP: "192.168.65.44", dnsServer: dnsServer)

        #expect(dnsServer.listEntries()["gone.example"] == nil)
        ConnectedNetworkAliases.shared.forget(nativeId: "connect-cleanup")
    }

    private func connect(_ app: Application, container: String, aliases: [String], network: String = NetworkConnectAliasesTests.network) async throws {
        let body = RESTNetworkConnect(
            Container: container,
            EndpointConfig: ContainerEndpointSettings(
                IPAMConfig: nil, Links: nil, Aliases: aliases, NetworkID: nil, EndpointID: nil, Gateway: nil,
                IPAddress: nil, IPPrefixLen: nil, IPv6Gateway: nil, GlobalIPv6Address: nil,
                GlobalIPv6PrefixLen: nil, MacAddress: nil, DriverOpts: nil)
        )
        try await app.testing().test(
            .POST, "/v1.51/networks/\(network)/connect",
            beforeRequest: { req in try req.content.encode(body, as: .json) }
        ) { res async in
            #expect(res.status == .ok)
        }
    }

    private func withNetworkRoutes(
        client: ClientContainerProtocol,
        dnsServer: SocktainerDNSServer,
        _ body: (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[SocktainerDNSServerKey.self] = dnsServer
            try app.register(collection: NetworkConnectRoute(client: client))
            try app.register(collection: NetworkDisconnectRoute(client: client))
            try await body(app)
        }
    }
}

private struct MissingContainerClient: ClientContainerProtocol {
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
