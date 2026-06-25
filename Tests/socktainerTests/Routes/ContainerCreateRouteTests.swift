import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression tests for the >16 KB request-body fix on `POST /containers/create`.
///
/// `Request.body.collect()` defaults to Vapor's `1 << 14` (16 KB) cap, and
/// `defaultMaxBodySize` is consulted *only* by Vapor's registered-route body
/// collection — which socktainer's `RegexRouter` bypasses (every route is served
/// from `RegexRoutingMiddleware`, not Vapor's route responder). So a
/// container-create payload over 16 KB (e.g. the env + config of Supabase's
/// edge-runtime / storage services) used to fail with `413 Payload Too Large`
/// before the handler ever ran. The fix makes the hand-collected body honor the
/// configured `defaultMaxBodySize`, so the cap is a deliberate policy knob, not a
/// silent 16 KB default.
///
/// These run against a LIVE server (`.running`) on an ephemeral port: the
/// in-memory tester delivers an already-`collected` body, for which
/// `collect(max:)` ignores the limit, so only a real streamed body exercises the
/// cap this fix is about.
@Suite("ContainerCreateRoute — request body size")
struct ContainerCreateRouteTests {

    /// The Abort error body shape (`{"error":true,"reason":"…"}`).
    private struct ErrorBody: Content { let reason: String }

    @Test("a >16 KB create body is collected, not rejected with 413")
    func largeBodyIsAccepted() async throws {
        // Valid create JSON, padded well past 16 KB via a large label value.
        let padding = String(repeating: "A", count: 20_000)
        let payload = #"{"Image":"socktainer-nonexistent-test-image:missing","Labels":{"pad":"\#(padding)"}}"#
        #expect(payload.utf8.count > 16_384)

        try await withCreateRouteApp(maxBodySize: "64mb") { app in
            try await app.testing(method: .running(hostname: "127.0.0.1", port: 0)).test(
                .POST, "/v1.51/containers/create?name=body-size-probe",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: payload)
            ) { res async throws in
                // The body streamed in and was collected past 16 KB; the request
                // then fails only at the image-existence check. With the bug the
                // body cap (16 KB) would raise 413 before the handler ran.
                #expect(res.status == .notFound)
                let err = try res.content.decode(ErrorBody.self)
                #expect(err.reason.contains("No such image"))
            }
        }
    }

    @Test("the configured body cap is still enforced (a body over the limit is 413)")
    func bodyOverCapIsRejected() async throws {
        // Cap below the body size — the body must be rejected at collection,
        // before the handler runs. Proves the fix bounds the buffer (DoS-safe),
        // it does not make collection unbounded. A 413 here can only come from
        // honoring the 1 KB cap.
        let payload = String(repeating: "A", count: 4_096)
        try await withCreateRouteApp(maxBodySize: "1kb") { app in
            try await app.testing(method: .running(hostname: "127.0.0.1", port: 0)).test(
                .POST, "/v1.51/containers/create?name=over-cap",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: payload)
            ) { res async in
                #expect(res.status == .payloadTooLarge)
            }
        }
    }

    @Test("an empty POST body returns 400, not a crash")
    func emptyBodyIsBadRequest() async throws {
        try await withCreateRouteApp(maxBodySize: "64mb") { app in
            try await app.testing().test(.POST, "/v1.51/containers/create?name=empty") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("a malformed JSON body returns 400, not 500")
    func malformedBodyIsBadRequest() async throws {
        try await withCreateRouteApp(maxBodySize: "64mb") { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/create?name=bad",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: "{ this is not valid json")
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }
}

// MARK: - Helpers

private func withCreateRouteApp(
    maxBodySize: ByteCount,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { app in
        // Map a thrown Abort (404 / 413) to its HTTP status so the tests can
        // observe it; without it an uncaught error has no defined HTTP mapping.
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
        // The body-size policy knob the hand-collected route now honors.
        app.routes.defaultMaxBodySize = maxBodySize
    }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.register(collection: ContainerCreateRoute(client: NoopContainerClient(), systemConfig: ContainerSystemConfig()))
        try await test(app)
    }
}

/// Minimal client — the create route returns 404 at the image-existence check
/// before it ever reaches the container backend, so every method is a no-op stub.
private struct NoopContainerClient: ClientContainerProtocol {
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
