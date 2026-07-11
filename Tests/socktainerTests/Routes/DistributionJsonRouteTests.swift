import ContainerizationError
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private actor FakeDistributionProvider: DistributionInspectProviding {
    let result: RESTDistributionInspect?
    let error: Error?
    private(set) var receivedReference: String?

    init(result: RESTDistributionInspect?, error: Error?) {
        self.result = result
        self.error = error
    }

    func inspect(reference: String, authentication: Authentication?) async throws -> RESTDistributionInspect {
        receivedReference = reference
        if let error { throw error }
        return result!
    }
}

private let alpineInspect = RESTDistributionInspect(
    Descriptor: .init(
        mediaType: "application/vnd.oci.image.index.v1+json",
        digest: "sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d",
        size: 1638
    ),
    Platforms: [
        .init(architecture: "arm64", os: "linux", variant: "v8"),
        .init(architecture: "amd64", os: "linux", variant: nil),
    ]
)

private func withDistributionApp(_ provider: FakeDistributionProvider, run: (Application) async throws -> Void) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
        try app.register(collection: DistributionJsonRoute(inspectProvider: provider))
        try await run(app)
    }
}

@Suite("DistributionJsonRoute")
struct DistributionJsonRouteTests {

    @Test("returns the Moby-shaped descriptor and platforms")
    func returnsInspect() async throws {
        try await withDistributionApp(FakeDistributionProvider(result: alpineInspect, error: nil)) { app in
            try await app.testing().test(.GET, "/v1.51/distribution/alpine/json") { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(RESTDistributionInspect.self)
                #expect(body.Descriptor.digest.hasPrefix("sha256:"))
                #expect(body.Platforms.count == 2)
                #expect(body.Platforms[0].architecture == "arm64")
            }
        }
    }

    @Test("slash-qualified references reach the provider intact")
    func slashQualifiedReference() async throws {
        let provider = FakeDistributionProvider(result: alpineInspect, error: nil)
        try await withDistributionApp(provider) { app in
            try await app.testing().test(.GET, "/v1.51/distribution/public.ecr.aws/docker/library/alpine/json") { res async in
                #expect(res.status == .ok)
            }
        }
        #expect(await provider.receivedReference == "public.ecr.aws/docker/library/alpine")
    }

    @Test("registry 404 answers manifest unknown")
    func manifestUnknown() async throws {
        let registryError = RegistryClient.Error.invalidStatus(url: "https://x", .notFound, reason: nil)
        try await withDistributionApp(FakeDistributionProvider(result: nil, error: registryError)) { app in
            try await app.testing().test(.GET, "/v1.51/distribution/ghost/json") { res async throws in
                #expect(res.status == .notFound)
                struct Body: Vapor.Content { let reason: String }
                let body = try res.content.decode(Body.self)
                #expect(body.reason.contains("manifest unknown"))
            }
        }
    }

    @Test("registry 401 answers unauthorized")
    func unauthorized() async throws {
        let registryError = RegistryClient.Error.invalidStatus(url: "https://x", .unauthorized, reason: "auth required")
        try await withDistributionApp(FakeDistributionProvider(result: nil, error: registryError)) { app in
            try await app.testing().test(.GET, "/v1.51/distribution/private/json") { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("provider-thrown 400s pass through untouched")
    func invalidReference() async throws {
        let parseError = Abort(.badRequest, reason: "invalid reference: UPPER!!bad")
        try await withDistributionApp(FakeDistributionProvider(result: nil, error: parseError)) { app in
            try await app.testing().test(.GET, "/v1.51/distribution/UPPER!!bad/json") { res async throws in
                #expect(res.status == .badRequest)
                struct Body: Vapor.Content { let reason: String }
                let body = try res.content.decode(Body.self)
                #expect(body.reason.contains("invalid reference"))
            }
        }
    }

    @Test("transport failures surface their reason instead of a masked 500")
    func transportFailure() async throws {
        struct ConnectionRefused: Error, CustomStringConvertible {
            var description: String { "Connection refused (localhost:5000)" }
        }
        try await withDistributionApp(FakeDistributionProvider(result: nil, error: ConnectionRefused())) { app in
            try await app.testing().test(.GET, "/v1.51/distribution/localhost:5000/img/json") { res async throws in
                #expect(res.status == .internalServerError)
                struct Body: Vapor.Content { let reason: String }
                let body = try res.content.decode(Body.self)
                #expect(body.reason.contains("Connection refused"))
            }
        }
    }

    @Test("X-Registry-Auth decodes docker's base64url credential JSON")
    func registryAuthHeader() {
        let json = #"{"username":"sylvain","password":"hunter2","serveraddress":"https://index.docker.io/v1/"}"#
        let header = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let decoded = DistributionJsonRoute.decodeRegistryAuth(header)
        #expect(decoded?.username == "sylvain")
        #expect(decoded?.password == "hunter2")

        #expect(DistributionJsonRoute.decodeRegistryAuth("not-base64!") == nil)
        #expect(DistributionJsonRoute.decodeRegistryAuth(Data("{}".utf8).base64EncodedString()) == nil)
    }
}
