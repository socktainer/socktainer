import Testing
import Vapor
import VaporTesting

@testable import socktainer

private struct MockHealthCheckClient: ClientHealthCheckProtocol {
    func ping() async throws {}
}

@Suite class HealthCheckPingRouteTests {

    private func withRoute(_ test: @escaping (Application) async throws -> Void) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: HealthCheckPingRoute(client: MockHealthCheckClient()))
            try await test(app)
        }
    }

    @Test
    func getPingReturnsOK() async throws {
        try await withRoute { app in
            try await app.testing().test(.GET, "/_ping") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "OK")
            }
        }
    }

    @Test
    func getPingReturnsExpectedHeaders() async throws {
        try await withRoute { app in
            try await app.testing().test(.GET, "/_ping") { res async in
                #expect(res.headers.first(name: "Api-Version") == "1.51")
                #expect(res.headers.first(name: "Docker-Experimental") == "false")
                #expect(res.headers.first(name: "Cache-Control") == "no-cache, no-store, must-revalidate")
                #expect(res.headers.first(name: "Pragma") == "no-cache")
            }
        }
    }

    @Test
    func headPingReturnsOKWithNoBody() async throws {
        try await withRoute { app in
            try await app.testing().test(.HEAD, "/_ping") { res async in
                #expect(res.status == .ok)
                #expect(res.body.readableBytes == 0)
            }
        }
    }

    @Test
    func headPingReturnsExpectedHeaders() async throws {
        try await withRoute { app in
            try await app.testing().test(.HEAD, "/_ping") { res async in
                #expect(res.headers.first(name: "Api-Version") == "1.51")
                #expect(res.headers.first(name: "Cache-Control") == "no-cache, no-store, must-revalidate")
            }
        }
    }
}
