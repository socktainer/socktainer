import Testing
import Vapor
import VaporTesting

@testable import GlassDock

@Suite("Registry authentication route")
struct AuthRouteTests {
    @Test("valid credentials return Docker login success")
    func validCredentials() async throws {
        let validator = FakeRegistryCredentialValidator()
        try await withApp(validator: validator) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/auth",
                beforeRequest: { request in
                    try request.content.encode(
                        AuthConfig(
                            username: "builder",
                            password: "secret",
                            email: nil,
                            serveraddress: "registry.example.test"
                        )
                    )
                },
                afterResponse: { response async throws in
                    #expect(response.status == .ok)
                    #expect(try response.content.decode(AuthResponse.self).Status == "Login Succeeded")
                }
            )
        }
        #expect(await validator.calls == 1)
    }

    @Test("missing credentials are rejected without registry access")
    func missingCredentials() async throws {
        let validator = FakeRegistryCredentialValidator()
        try await withApp(validator: validator) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/auth",
                beforeRequest: { request in
                    try request.content.encode(
                        AuthConfig(
                            username: "builder", password: nil, email: nil,
                            serveraddress: "registry.example.test"
                        )
                    )
                },
                afterResponse: { response async throws in
                    #expect(response.status == .unauthorized)
                }
            )
        }
        #expect(await validator.calls == 0)
    }

    private func withApp(
        validator: any RegistryCredentialValidating,
        _ body: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        let router = app.regexRouter(with: app.logger)
        app.setRegexRouter(router)
        router.installMiddleware(on: app)
        try app.register(collection: AuthRoute(validator: validator))
        do {
            try await body(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}

private actor FakeRegistryCredentialValidator: RegistryCredentialValidating {
    private(set) var calls = 0

    func validate(serverAddress: String, username: String, password: String) async throws {
        calls += 1
    }
}
