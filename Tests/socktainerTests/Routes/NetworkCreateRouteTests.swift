import ContainerResource
import ContainerizationExtras
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression tests for the idempotent `POST /networks/create` fix (#249).
///
/// Docker's `network create` is create-to-ensure: tools such as the Supabase CLI
/// issue it more than once for the same name during a single bring-up and treat a
/// duplicate-create error as fatal. socktainer's underlying create throws
/// "already exists"; the route must catch *that specific* conflict and return the
/// existing network, while still letting every other failure propagate.
/// (Mirrors the idempotent `VolumeCreateRoute`.)
@Suite("NetworkCreateRoute — idempotent create")
struct NetworkCreateRouteTests {

    @Test("first create returns 200 with the created network")
    func firstCreateSucceeds() async throws {
        let client = FakeNetworkClient()
        try await withNetworkRouteApp(client: client) { app in
            try await app.testing().test(
                .POST, "/v1.51/networks/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"net-a"}"#)
            ) { res async throws in
                #expect(res.status == .ok)
                let created = try res.content.decode(RESTNetworkCreate.self)
                #expect(created.Id == "net-a")
            }
        }
        #expect(client.createCalls == 1)
        #expect(client.getNetworkCalls == 0)
    }

    @Test("duplicate create is idempotent: returns the existing network, not an error (#249)")
    func duplicateCreateIsIdempotent() async throws {
        let client = FakeNetworkClient()
        try await withNetworkRouteApp(client: client) { app in
            // First create — establishes the network.
            try await app.testing().test(
                .POST, "/v1.51/networks/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"net-a"}"#)
            ) { res async in
                #expect(res.status == .ok)
            }
            // Second create for the same name — must NOT be fatal.
            try await app.testing().test(
                .POST, "/v1.51/networks/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"net-a"}"#)
            ) { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(RESTNetworkCreate.self)
                #expect(body.Id == "net-a")
            }
        }
        #expect(client.createCalls == 2, "both creates reach the backend")
        #expect(client.getNetworkCalls == 1, "the conflict is resolved by looking up the existing network")
    }

    @Test("a non-\"already exists\" create failure still propagates (not swallowed)")
    func otherErrorPropagates() async throws {
        let client = FakeNetworkClient()
        client.createThrowsOther = true
        try await withNetworkRouteApp(client: client) { app in
            try await app.testing().test(
                .POST, "/v1.51/networks/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"net-a"}"#)
            ) { res async in
                #expect(res.status == .internalServerError)
            }
        }
        #expect(client.createCalls == 1)
        #expect(client.getNetworkCalls == 0, "non-conflict errors must not trigger an existing-network lookup")
    }

    @Test("\"already exists\" but the network can't be found rethrows the original error")
    func vanishedNetworkRethrows() async throws {
        let client = FakeNetworkClient()
        try await withNetworkRouteApp(client: client) { app in
            // Establish the network so the second create hits "already exists".
            try await app.testing().test(
                .POST, "/v1.51/networks/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"net-a"}"#)
            ) { res async in
                #expect(res.status == .ok)
            }
            // Simulate the network being deleted between the failed create and the
            // lookup — the route must not return a bogus 200, it rethrows.
            client.getNetworkReturnsNil = true
            try await app.testing().test(
                .POST, "/v1.51/networks/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"net-a"}"#)
            ) { res async in
                #expect(res.status == .internalServerError)
            }
        }
        #expect(client.createCalls == 2)
        #expect(client.getNetworkCalls == 1)
    }
}

// MARK: - Helpers

private func withNetworkRouteApp(
    client: ClientNetworkProtocol,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { app in
        // Surface a thrown (rethrown) error as a 500 so the propagation tests can
        // observe it; without it an uncaught error has no defined HTTP mapping.
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
    }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.register(collection: NetworkCreateRoute(client: client))
        try await test(app)
    }
}

private struct AlreadyExistsError: Error, CustomStringConvertible {
    let name: String
    var description: String { "network \(name) already exists" }
}

private struct OtherError: Error, CustomStringConvertible {
    var description: String { "some unrelated failure" }
}

private func makeNetworkResource(name: String) throws -> NetworkResource {
    let configuration = try NetworkConfiguration(
        name: name,
        mode: .nat,
        ipv4Subnet: nil,
        labels: ResourceLabels([:]),
        plugin: "container-network-vmnet"
    )
    let status = NetworkStatus(
        ipv4Subnet: try CIDRv4("192.168.100.0/24"),
        ipv4Gateway: try IPv4Address("192.168.100.1"),
        ipv6Subnet: nil
    )
    return NetworkResource(configuration: configuration, status: status)
}

/// In-memory `ClientNetworkProtocol`. `create` is first-wins: a second create for
/// a name it already holds throws an "already exists" error, exactly as the Apple
/// Container backend does.
private final class FakeNetworkClient: ClientNetworkProtocol, @unchecked Sendable {
    private(set) var createCalls = 0
    private(set) var getNetworkCalls = 0
    /// When true, `getNetwork` reports the network as absent (simulates a network
    /// deleted between the failed create and the lookup).
    var getNetworkReturnsNil = false
    /// When true, `create` fails with a non-"already exists" error.
    var createThrowsOther = false
    private var existing: Set<String> = []

    func list(filters: String?, logger: Logger) async throws -> [RESTNetworkSummary] { [] }

    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary? {
        getNetworkCalls += 1
        guard !getNetworkReturnsNil, existing.contains(id) else { return nil }
        return RESTNetworkSummary(networkResource: try makeNetworkResource(name: id))
    }

    func delete(id: String, logger: Logger) async throws {}

    func create(name: String, labels: [String: String], logger: Logger) async throws -> RESTNetworkCreate {
        createCalls += 1
        if createThrowsOther { throw OtherError() }
        guard existing.insert(name).inserted else { throw AlreadyExistsError(name: name) }
        return RESTNetworkCreate(Id: name, Warning: "")
    }

    deinit {}
}
