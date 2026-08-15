import Testing
import Vapor
import VaporTesting

@testable import GlassDock

@Suite("Persistent runtime readiness middleware")
struct RuntimeReadinessTests {
    @Test("A failed initialization can be retried")
    func failedInitializationCanRetry() async throws {
        let starts = StartAttempts()
        let readiness = RuntimeReadiness {
            if await starts.begin() == 1 { throw TestFailure.notReady }
        }
        while await starts.count() == 0 {
            await Task.yield()
        }
        while true {
            do {
                try await readiness.waitUntilReady()
                break
            } catch {
                await Task.yield()
            }
        }
        #expect(await starts.count() == 2)
        await readiness.cancel()
    }

    @Test("Docker ping is available while runtime initialization is incomplete")
    func pingDoesNotWaitForRuntime() async throws {
        let readiness = RecordingRuntimeReadiness(result: .failure(TestFailure.notReady))
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.middleware.use(RuntimeReadinessMiddleware(readiness: readiness))
            try app.register(collection: HealthCheckPingRoute())

            try await app.testing().test(.GET, "/_ping") { response async in
                #expect(response.status == .ok)
                #expect(response.body.string == "OK")
            }
            #expect(await readiness.waitCount() == 0)

            try await app.testing().test(.HEAD, "/v1.51/_ping") { response async in
                #expect(response.status == .ok)
            }
            #expect(await readiness.waitCount() == 0)
        }
    }

    @Test("Capability-dependent routes wait for runtime initialization")
    func workloadWaitsForRuntime() async throws {
        let readiness = RecordingRuntimeReadiness(result: .failure(TestFailure.notReady))
        try await withApp(configure: { _ in }) { app in
            app.middleware.use(ErrorMiddleware.default(environment: app.environment))
            app.middleware.use(RuntimeReadinessMiddleware(readiness: readiness))
            app.get("work") { _ in "ready" }

            try await app.testing().test(.GET, "/work") { response async in
                #expect(response.status == .internalServerError)
            }
            #expect(await readiness.waitCount() == 1)
        }
    }

    @Test("Non-version prefixes cannot bypass runtime readiness")
    func invalidVersionDoesNotBypassRuntime() async throws {
        let readiness = RecordingRuntimeReadiness(result: .failure(TestFailure.notReady))
        try await withApp(configure: { _ in }) { app in
            app.middleware.use(ErrorMiddleware.default(environment: app.environment))
            app.middleware.use(RuntimeReadinessMiddleware(readiness: readiness))
            app.get("vanity", "_ping") { _ in "wrong" }

            try await app.testing().test(.GET, "/vanity/_ping") { response async in
                #expect(response.status == .internalServerError)
            }
            #expect(await readiness.waitCount() == 1)
        }
    }
}

private enum TestFailure: Error { case notReady }

private actor StartAttempts {
    private var attempts = 0
    func begin() -> Int {
        attempts += 1
        return attempts
    }
    func count() -> Int { attempts }
}

private actor RecordingRuntimeReadiness: RuntimeReadying {
    private let result: Result<Void, Error>
    private var waits = 0

    init(result: Result<Void, Error>) { self.result = result }

    func waitUntilReady() async throws {
        waits += 1
        try result.get()
    }

    func waitCount() -> Int { waits }
}
