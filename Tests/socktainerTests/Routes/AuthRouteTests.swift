import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Body-size regression for `POST /auth`, the other hand-collected route.
///
/// `AuthRoute` collects the body with `req.body.collect()` so a later
/// `req.content.decode` can read it; without an explicit `max` that silently
/// caps at Vapor's 16 KB default (the RegexRouter bypasses `defaultMaxBodySize`),
/// so a large auth payload would 413 before the handler runs. Same fix and same
/// live-server reasoning as `ContainerCreateRouteTests` (the in-memory tester
/// delivers an already-`collected` body, for which `collect(max:)` ignores the
/// limit, so only a real streamed body exercises the cap).
@Suite("AuthRoute — request body size")
struct AuthRouteTests {

    @Test("a >16 KB auth body is collected, not rejected with 413")
    func largeBodyIsAccepted() async throws {
        // Valid JSON padded past 16 KB (a large, ignored field), with no
        // username — so the handler reaches its own validation and returns 401,
        // proving the body was collected. With the bug this is 413 first.
        let padding = String(repeating: "A", count: 20_000)
        let payload = #"{"email":"\#(padding)"}"#
        #expect(payload.utf8.count > 16_384)

        try await withAuthRouteApp(maxBodySize: "64mb") { app in
            try await app.testing(method: .running(hostname: "127.0.0.1", port: 0)).test(
                .POST, "/v1.51/auth",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: payload)
            ) { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("the configured body cap is still enforced (a body over the limit is 413)")
    func bodyOverCapIsRejected() async throws {
        let payload = String(repeating: "A", count: 4_096)  // > 1 KB cap
        try await withAuthRouteApp(maxBodySize: "1kb") { app in
            try await app.testing(method: .running(hostname: "127.0.0.1", port: 0)).test(
                .POST, "/v1.51/auth",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: payload)
            ) { res async in
                #expect(res.status == .payloadTooLarge)
            }
        }
    }

    @Test("an empty POST returns 400, not 500")
    func emptyBodyIsBadRequest() async throws {
        try await withAuthRouteApp(maxBodySize: "64mb") { app in
            try await app.testing().test(.POST, "/v1.51/auth") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }
}

// MARK: - Helpers

private func withAuthRouteApp(
    maxBodySize: ByteCount,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { app in
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
        app.routes.defaultMaxBodySize = maxBodySize
    }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        // The route's registry client is never reached on the 401 / 413 paths
        // these tests exercise.
        try app.register(collection: AuthRoute(client: ClientRegistryService()))
        try await test(app)
    }
}
