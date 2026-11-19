import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Apple Container only accepts lowercase network names, so socktainer stores them
/// lowercased. A client that created `Mixed-Case.Test` must still be able to inspect
/// and delete it by that name, and attach containers to it.
@Suite("Mixed-case network names")
struct NetworkMixedCaseNameTests {

    @Test("inspect resolves a mixed-case name to the stored lowercase network")
    func inspectResolvesMixedCase() async throws {
        let client = LookupNetworkClient(names: ["mixed-case.test"])
        try await withNetworkApp(client: client) { app in
            try await app.testing().test(.GET, "/v1.51/networks/Mixed-Case.Test") { res async throws in
                #expect(res.status == .ok)
                let network = try res.content.decode(RESTNetworkSummary.self)
                #expect(network.Name == "mixed-case.test")
            }
        }
    }

    @Test("delete resolves a mixed-case name to the stored lowercase network")
    func deleteResolvesMixedCase() async throws {
        let client = LookupNetworkClient(names: ["mixed-case.test"])
        try await withNetworkApp(client: client) { app in
            try await app.testing().test(.DELETE, "/v1.51/networks/Mixed-Case.Test") { res async in
                #expect(res.status == .noContent)
            }
        }
        #expect(client.deletedIds == ["mixed-case.test"])
    }

    @Test("delete falls back to the lowercase name when the lookup fails")
    func deleteFallsBackToLowercase() async throws {
        let client = LookupNetworkClient(names: [])
        try await withNetworkApp(client: client) { app in
            try await app.testing().test(.DELETE, "/v1.51/networks/Mixed-Case.Test") { res async in
                #expect(res.status == .noContent)
            }
        }
        #expect(client.deletedIds == ["mixed-case.test"])
    }

    @Test("container attachments from EndpointsConfig keys are lowercased")
    func endpointsConfigKeysLowercased() {
        let networks = ContainerCreateRoute.attachmentNetworks(
            endpointsConfigKeys: ["aspire-session-network-ghfpwpdj-MyApp.Web"], legacyNetworkKeys: [], networkMode: nil)
        #expect(networks == ["aspire-session-network-ghfpwpdj-myapp.web"])
    }

    @Test("container attachments from legacy Networks keys are lowercased")
    func legacyNetworkKeysLowercased() {
        let networks = ContainerCreateRoute.attachmentNetworks(
            endpointsConfigKeys: [], legacyNetworkKeys: ["Mixed-Case.Test"], networkMode: nil)
        #expect(networks == ["mixed-case.test"])
    }

    @Test("a custom NetworkMode is lowercased")
    func customNetworkModeLowercased() {
        let networks = ContainerCreateRoute.attachmentNetworks(
            endpointsConfigKeys: [], legacyNetworkKeys: [], networkMode: "Mixed-Case.Test")
        #expect(networks == ["mixed-case.test"])
    }

    @Test("reserved network modes map to default", arguments: ["host", "none", "bridge"])
    func reservedModesMapToDefault(mode: String) {
        let networks = ContainerCreateRoute.attachmentNetworks(endpointsConfigKeys: [], legacyNetworkKeys: [], networkMode: mode)
        #expect(networks == ["default"])
    }

    @Test("no networking config falls back to default")
    func noConfigFallsBackToDefault() {
        #expect(ContainerCreateRoute.attachmentNetworks(endpointsConfigKeys: [], legacyNetworkKeys: [], networkMode: nil) == ["default"])
        #expect(ContainerCreateRoute.attachmentNetworks(endpointsConfigKeys: [], legacyNetworkKeys: [], networkMode: "") == ["default"])
    }

    @Test("EndpointsConfig keys take priority over legacy Networks and NetworkMode")
    func endpointsConfigTakesPriority() {
        let networks = ContainerCreateRoute.attachmentNetworks(
            endpointsConfigKeys: ["Primary"], legacyNetworkKeys: ["Legacy"], networkMode: "Mode")
        #expect(networks == ["primary"])
    }

    @Test("firstNamedNetwork returns the lowercase name so DNS matches the attachment")
    func firstNamedNetworkLowercased() {
        #expect(ContainerCreateRoute.firstNamedNetwork(endpointsConfigKeys: ["Mixed-Case.Test"], networkMode: nil) == "mixed-case.test")
        #expect(ContainerCreateRoute.firstNamedNetwork(endpointsConfigKeys: [], networkMode: "Mixed-Case.Test") == "mixed-case.test")
        #expect(ContainerCreateRoute.firstNamedNetwork(endpointsConfigKeys: [], networkMode: "host") == nil)
    }
}

// MARK: - Helpers

private func withNetworkApp(
    client: ClientNetworkProtocol,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { app in
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
    }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.register(collection: NetworkInspectRoute(client: client))
        try app.register(collection: NetworkDeleteRoute(client: client))
        try await test(app)
    }
}

/// Holds a fixed set of stored (lowercase) networks and resolves lookups the same
/// way `ClientNetworkService.getNetwork` does.
private final class LookupNetworkClient: ClientNetworkProtocol, @unchecked Sendable {
    private let names: [String]
    private(set) var deletedIds: [String] = []

    init(names: [String]) { self.names = names }

    func list(filters: String?, logger: Logger) async throws -> [RESTNetworkSummary] {
        try names.map { try makeSummary($0) }
    }

    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary? {
        ClientNetworkService.findNetwork(in: try await list(filters: nil, logger: logger), reference: id)
    }

    func delete(id: String, logger: Logger) async throws {
        deletedIds.append(id)
    }

    func create(name: String, labels: [String: String], ipv4Subnet: String?, mode: NetworkMode, logger: Logger) async throws -> RESTNetworkCreate {
        RESTNetworkCreate(Id: name, Warning: "")
    }
}
