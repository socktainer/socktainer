import ContainerResource
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// `LibpodNetworkInspectRoute`/`LibpodNetworkDeleteRoute` delegate to the Docker-compat
/// `NetworkInspectRoute`/`NetworkDeleteRoute` handlers, which read the path parameter under
/// the key `"id"` — registering the libpod route's own pattern with `{name}` instead of
/// `{id}` left that key unset for every request, regardless of what network name the
/// caller actually specified.
@Suite("LibpodNetworkInspectRoute / LibpodNetworkDeleteRoute — path parameter binding")
struct LibpodNetworkParamBindingTests {
    @Test("the network name in the URL reaches the handler as the 'id' parameter, not lost")
    func inspectResolvesNetworkFromPath() async throws {
        let client = StubNetworkClient(summary: makeSummary(name: "mynet"))

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodNetworkInspectRoute(client: client))

            try await app.testing().test(.GET, "/v1.51/libpod/networks/mynet/json") { res async throws in
                #expect(res.status == .ok)
                // podman's `types.Network` uses lower-case keys and a 64-hex id.
                let body = try #require(try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])
                #expect(body["name"] as? String == "mynet")
                #expect((body["id"] as? String)?.count == 64)
            }
        }
        #expect(await client.requestedId == "mynet")
    }

    @Test("the network name in the URL reaches the delete handler as the 'id' parameter, not lost")
    func deleteResolvesNetworkFromPath() async throws {
        let client = StubNetworkClient(summary: makeSummary(name: "mynet"))

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodNetworkDeleteRoute(dockerRoute: NetworkDeleteRoute(client: client)))

            try await app.testing().test(.DELETE, "/v1.51/libpod/networks/mynet") { res async throws in
                // podman's `network.Remove` decodes a `[]NetworkRmReport` even on success.
                #expect(res.status == .ok)
                let reports = try #require(try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [[String: Any]])
                #expect(reports.first?["Name"] as? String == "mynet")
            }
        }
        #expect(await client.deletedId == "mynet")
    }
}

/// The libpod routes report a network's id as a hash of its name; podman then sends that id (or
/// its first 12 characters, as `podman network ls` prints it) back to inspect/rm/exists.
@Suite("Libpod network routes — libpod network ids")
struct LibpodNetworkIDTests {
    private let shortID = String(LibpodSchema.networkID("mynet").prefix(12))

    private func withLibpodApp(_ body: (Application) async throws -> Void) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try await body(app)
        }
    }

    @Test("inspect resolves a full or abbreviated libpod id to the network")
    func inspectByLibpodID() async throws {
        let client = StubNetworkClient(summary: makeSummary(name: "mynet"))
        try await withLibpodApp { app in
            try app.register(collection: LibpodNetworkInspectRoute(client: client))
            for id in [shortID, LibpodSchema.networkID("mynet")] {
                try await app.testing().test(.GET, "/v1.51/libpod/networks/\(id)/json") { res async throws in
                    #expect(res.status == .ok)
                    let body = try #require(try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])
                    #expect(body["name"] as? String == "mynet")
                }
            }
        }
    }

    @Test("delete and exists resolve an abbreviated libpod id")
    func deleteAndExistsByLibpodID() async throws {
        let client = StubNetworkClient(summary: makeSummary(name: "mynet"))
        try await withLibpodApp { app in
            try app.register(collection: LibpodNetworkExistsRoute(client: client))
            try app.register(collection: LibpodNetworkDeleteRoute(dockerRoute: NetworkDeleteRoute(client: client)))
            try await app.testing().test(.GET, "/v1.51/libpod/networks/\(shortID)/exists") { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.GET, "/v1.51/libpod/networks/abcdef123456/exists") { res async in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.DELETE, "/v1.51/libpod/networks/\(shortID)") { res async in
                #expect(res.status == .ok)
            }
        }
        #expect(await client.deletedId == "mynet")
    }

    @Test("a failed network removal fails the prune instead of reporting success")
    func pruneSurfacesErrors() throws {
        #expect(throws: Abort.self) {
            try LibpodNetworkPruneRoute.reports(from: ["NetworksDeleted": ["a"], "Errors": ["b": "in use"]] as [String: Any])
        }
        let reports = try #require(try LibpodNetworkPruneRoute.reports(from: ["NetworksDeleted": ["a"], "Errors": [String: Any]()]) as? [[String: Any]])
        #expect(reports.map { $0["Name"] as? String } == ["a"])
    }

    @Test("create reports the subnet the backend allocated when the request named none")
    func createReportsAllocatedSubnet() async throws {
        let client = StubNetworkClient(
            summary: makeSummary(name: "mynet", config: [NetworkIPAMConfig(Subnet: "192.168.64.0/24", IPRange: nil, Gateway: "192.168.64.1", AuxiliaryAddresses: nil)]))
        try await withLibpodApp { app in
            try app.register(collection: LibpodNetworkCreateRoute(dockerRoute: NetworkCreateRoute(client: client)))
            try await app.testing().test(
                .POST, "/v1.51/libpod/networks/create", beforeRequest: { req in req.body = ByteBuffer(string: #"{"name":"mynet"}"#) }
            ) { res async throws in
                #expect(res.status == .ok)
                let body = try #require(try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])
                let subnets = body["subnets"] as? [[String: Any]]
                #expect(subnets?.first?["subnet"] as? String == "192.168.64.0/24")
                #expect(subnets?.first?["gateway"] as? String == "192.168.64.1")
            }
        }
    }
}

private func makeSummary(name: String, config: [NetworkIPAMConfig] = []) -> RESTNetworkSummary {
    RESTNetworkSummary(
        Name: name,
        Id: name,
        Created: "",
        Scope: "local",
        Driver: "nat",
        EnableIPv4: true,
        EnableIPv6: false,
        Internal: false,
        Attachable: false,
        Ingress: false,
        IPAM: NetworkIPAM(Driver: "default", Config: config),
        Options: [:],
        Containers: nil,
        ConfigFrom: nil,
        Labels: [:],
        Subnet: nil,
        Gateway: nil
    )
}

private actor StubNetworkClient: ClientNetworkProtocol {
    private let summary: RESTNetworkSummary
    private(set) var requestedId: String?
    private(set) var deletedId: String?

    init(summary: RESTNetworkSummary) {
        self.summary = summary
    }

    func list(filters: String?, logger: Logger) async throws -> [RESTNetworkSummary] { [summary] }

    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary? {
        requestedId = id
        return id == summary.Name ? summary : nil
    }

    func delete(id: String, logger: Logger) async throws {
        deletedId = id
    }

    func create(name: String, labels: [String: String], ipv4Subnet: String?, mode: NetworkMode, logger: Logger) async throws -> RESTNetworkCreate {
        RESTNetworkCreate(Id: name, Warning: "")
    }
}
