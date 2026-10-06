import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("Container rename — Compose recreation", .serialized)
struct ContainerRenameRouteTests {
    private func withRoutes(
        status: RuntimeStatus = .running,
        _ test: (Application, RenameClient, ContainerSnapshot, SocktainerDNSServer) async throws -> Void
    ) async throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "rename-" + UUID().uuidString.lowercased(), ip: "10.0.0.5", network: "rename_default",
            labels: ["com.docker.compose.service": "database"], status: status)
        let client = RenameClient(containers: [snapshot])
        let dns = SocktainerDNSServer()
        try await withApp(configure: { _ in }) { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            router.installMiddleware(on: app)
            app.storage[SocktainerDNSServerKey.self] = dns
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerRenameRoute(client: client))
            try app.register(collection: ContainerListRoute(client: client))
            try app.register(collection: ContainerInspectRoute(client: client))
            try app.register(collection: ContainerDeleteRoute(client: client))
            try app.register(collection: ContainerPruneRoute(client: client))
            try await test(app, client, snapshot, dns)
        }
        try await ContainerNameOverrideStore.shared.remove(nativeID: snapshot.id)
    }

    @Test("rename after deleting the old service restores canonical inspect/list and keeps the Docker ID")
    func recreate() async throws {
        try await withRoutes(status: .stopped) { app, client, replacement, _ in
            let name = "compose-database-1"
            let old = try makeContainerSnapshot(nativeId: name, networks: [], labels: [:])
            await client.insert(old)
            let id = DockerContainerID.hexId(for: replacement)
            try await app.testing().test(.POST, "/v1.51/containers/\(id)/rename?name=\(name)") { res async in
                #expect(res.status == .conflict)
            }
            try await app.testing().test(.DELETE, "/v1.51/containers/\(name)") { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.POST, "/v1.51/containers/\(id)/rename?name=\(name)") { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.GET, "/v1.51/containers/\(name)/json") { res async throws in
                let inspected = try res.content.decode(RESTContainerInspect.self)
                #expect(inspected.Name == "/" + name)
                #expect(inspected.Id == id)
            }
            let filters = #"{"name":["^/compose-database-[0-9]+$"]}"#
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            try await app.testing().test(.GET, "/v1.51/containers/json?all=true&filters=\(filters)") { res async throws in
                let listed = try res.content.decode([RESTContainerSummary].self)
                #expect(listed.count == 1)
                #expect(listed.first?.Names == ["/" + name])
                #expect(listed.first?.Id == id)
            }
            // Creating another container with the canonical name must fail before the
            // create operation runs, even though that name is free in Apple Container.
            await #expect(throws: Abort.self) {
                try await ContainerNameOverrideStore.shared.withAvailableName(name, client: client) {
                    Issue.record("create should not run while a renamed container owns its name")
                }
            }
        }
    }

    @Test("DNS rename works after daemon restart without the start cache and keeps service aliases")
    func dnsAfterRestart() async throws {
        try await withRoutes { app, _, snapshot, dns in
            dns.register(hostname: snapshot.id, ip: "10.0.0.5")
            dns.register(hostname: "database", ip: "10.0.0.5")
            #expect(await ContainerInfoCache.shared.get(id: snapshot.id) == nil)
            try await app.testing().test(.POST, "/v1.51/containers/\(snapshot.id)/rename?name=canonical-db") { res async in
                #expect(res.status == .noContent)
            }
            #expect(dns.listEntries()[snapshot.id] == nil)
            #expect(dns.listEntries()["canonical-db"] == "10.0.0.5")
            #expect(dns.listEntries()["database"] == "10.0.0.5")
            let resumedDNS = SocktainerDNSServer()
            await ContainerStartRoute.registerDNSAliasesOnResume(container: snapshot, dnsServer: resumedDNS, logger: app.logger)
            #expect(resumedDNS.listEntries()["canonical-db"] == "10.0.0.5")
            #expect(resumedDNS.listEntries()[snapshot.id] == nil)
        }
    }

    @Test("rename back, repeated rename, leading slash, and validation")
    func validation() async throws {
        try await withRoutes { app, _, snapshot, _ in
            for name in ["", "bad%20name", "bad%2Fname", "-bad", "bad%0A"] {
                try await app.testing().test(.POST, "/v1.51/containers/\(snapshot.id)/rename?name=\(name)") { res async in
                    #expect(res.status == .badRequest)
                }
            }
            try await app.testing().test(.POST, "/v1.51/containers/missing/rename?name=valid") { res async in
                #expect(res.status == .notFound)
            }
            for name in ["%2Fcanonical-db", "canonical-db", snapshot.id] {
                try await app.testing().test(.POST, "/v1.51/containers/\(snapshot.id)/rename?name=\(name)") { res async in
                    #expect(res.status == .noContent)
                }
            }
            #expect(await ContainerNameOverrideStore.shared.nativeID(forName: "canonical-db") == nil)
        }
    }

    @Test("delete and prune release renamed names and DNS entries", arguments: [false, true])
    func cleanup(prune: Bool) async throws {
        try await withRoutes { app, _, snapshot, dns in
            try await app.testing().test(.POST, "/v1.51/containers/\(snapshot.id)/rename?name=canonical-db") { res async in
                #expect(res.status == .noContent)
            }
            if prune {
                try await app.testing().test(.POST, "/v1.51/containers/prune") { res async in
                    #expect(res.status == .ok)
                }
            } else {
                try await app.testing().test(.DELETE, "/v1.51/containers/canonical-db?force=true") { res async in
                    #expect(res.status == .noContent)
                }
            }
            #expect(await ContainerNameOverrideStore.shared.nativeID(forName: "canonical-db") == nil)
            #expect(dns.listEntries()["canonical-db"] == nil)
        }
    }

    @Test("concurrent rename requests have one name owner")
    func concurrentRenames() async throws {
        try await withRoutes { app, client, snapshot, _ in
            let other = try makeContainerSnapshot(nativeId: "other-native", networks: [], labels: [:])
            await client.insert(other)
            let handler = ContainerRenameRoute.handler(client: client)
            func rename(_ id: String) async throws -> HTTPStatus {
                let req = Request(application: app, method: .POST, url: "/?name=winner", on: app.eventLoopGroup.next())
                req.parameters.set("id", to: id)
                do { return try await handler(req) } catch let abort as Abort { return abort.status }
            }
            async let first = rename(snapshot.id)
            async let second = rename(other.id)
            let statuses = try await [first, second]
            #expect(statuses.filter { $0 == .noContent }.count == 1)
            #expect(statuses.filter { $0 == .conflict }.count == 1)
            try await ContainerNameOverrideStore.shared.remove(nativeID: other.id)
        }
    }
}

private actor RenameClient: ClientContainerProtocol {
    var containers: [ContainerSnapshot]
    init(containers: [ContainerSnapshot]) { self.containers = containers }
    func insert(_ snapshot: ContainerSnapshot) { containers.append(snapshot) }
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        ClientContainerService.applyFilters(containers, filters: filters, names: await ContainerNameOverrideStore.shared.snapshot())
    }
    func getContainer(id: String) async throws -> ContainerSnapshot? {
        let nativeID = await ContainerNameOverrideStore.shared.nativeID(forName: id) ?? id
        return containers.first { $0.id == nativeID || DockerContainerID.hexId(for: $0) == id }
    }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {
        if let snapshot = try await getContainer(id: id) { containers.removeAll { $0.id == snapshot.id } }
    }
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait { RESTContainerWait(statusCode: 0) }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        let ids = containers.map(\.id)
        containers = []
        return (ids, 0)
    }
}
