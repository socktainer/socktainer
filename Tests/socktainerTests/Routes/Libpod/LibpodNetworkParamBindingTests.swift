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
                let body = try JSONDecoder().decode(RESTNetworkSummary.self, from: Data(buffer: res.body))
                #expect(body.Name == "mynet")
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
                #expect(res.status == .noContent)
            }
        }
        #expect(await client.deletedId == "mynet")
    }
}

private func makeSummary(name: String) -> RESTNetworkSummary {
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
        IPAM: NetworkIPAM(Driver: "default", Config: []),
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

    func create(name: String, labels: [String: String], ipv4Subnet: String?, logger: Logger) async throws -> RESTNetworkCreate {
        RESTNetworkCreate(Id: name, Warning: "")
    }
}
