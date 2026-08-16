import Testing
import Vapor
import VaporTesting

@testable import GlassDock

@Suite class HealthCheckPingRouteTests {

    private func withRoute(_ test: @escaping (Application) async throws -> Void) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            try app.register(collection: HealthCheckPingRoute())
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
                #expect(res.headers.first(name: "Api-Version") == DockerPing.apiVersion)
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

    @Test("pre-router responder bypasses registered ping handler")
    func responderBypassesRouter() async throws {
        try await withApp(configure: { _ in }) { app in
            app.get("_ping") { _ in Response(status: .imATeapot) }
            app.get("normal") { _ in "routed" }
            app.responder.use { application in
                DockerPingResponder(next: application.responder.default)
            }

            try await app.testing().test(.GET, "/_ping") { response async in
                #expect(response.status == .ok)
                #expect(response.body.string == "OK")
            }
            try await app.testing().test(.GET, "/normal") { response async in
                #expect(response.status == .ok)
                #expect(response.body.string == "routed")
            }
        }
    }

    @Test(
        "ping matcher accepts only Docker paths and methods",
        arguments: [
            (HTTPMethod.GET, "/_ping", true),
            (HTTPMethod.HEAD, "/v1.51/_ping", true),
            (HTTPMethod.POST, "/_ping", false),
            (HTTPMethod.GET, "/vanity/_ping", false),
            (HTTPMethod.GET, "/v1.51.0/_ping", false),
            (HTTPMethod.GET, "/v١.٥١/_ping", false),
            (HTTPMethod.GET, "/v1./_ping", false),
        ]
    )
    func matcher(method: HTTPMethod, path: String, expected: Bool) {
        #expect(DockerPing.matches(method: method, path: path) == expected)
    }
}
