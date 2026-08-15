import Foundation
import Testing
import Vapor
import VaporTesting

@testable import GlassDock

@Suite class RegexRouterTests {

    // Configure function for testing
    private func configure(_ app: Application) throws {
        // Basic configuration for tests
    }

    // Helper to set up RegexRouter for testing
    private func setupRegexRouter(for app: Application) {
        // Create the greedy-path fallback router.
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
    }

    // Create a fresh app instance for each test
    private func makeApp() async throws -> Application {
        try await Application.make(.testing)
    }

    // Helper to reduce code duplication for tests that need RegexRouter setup
    private func withRegexRouter(_ test: @escaping (Application) async throws -> Void) async throws {
        try await withApp(configure: configure) { app in
            setupRegexRouter(for: app)
            try await test(app)
        }
    }

    @Test
    func regexRouterInstance() async throws {
        let app = try await makeApp()
        setupRegexRouter(for: app)

        let router1 = app.regexRouter
        let router2 = app.regexRouter
        #expect(router1 === router2)

        try await app.asyncShutdown()
    }

    @Test
    func ordinaryRoutesBypassRegexFallback() async throws {
        try await withRegexRouter { app in
            try app.registerVersionedRoute(.POST, pattern: "/containers/{id}/start") { request in
                request.parameters.get("id") ?? ""
            }

            #expect(app.regexRouter.fallbackRouteCount == 0)

            try await app.testing().test(.POST, "/v1.51/containers/example/start") { response async throws in
                #expect(response.status == .ok)
                #expect(response.body.string == "example")
            }
        }
    }

    @Test
    func greedyRoutesUseRegexFallback() async throws {
        try await withRegexRouter { app in
            try app.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/json") { request in
                request.parameters.get("name") ?? ""
            }

            #expect(app.regexRouter.fallbackRouteCount == 1)
        }
    }

    @Test
    func vaporPatternConversion() async throws {
        try await withRegexRouter { app in
            // Test simple pattern conversion
            try app.registerVersionedRoute(.GET, pattern: "/images/{id:.*}/json") { req in
                "test"
            }

            // Test multiple parameters
            try app.registerVersionedRoute(.POST, pattern: "/users/{userId}/posts/{postId}") { req in
                "test"
            }
        }
    }

    @Test
    func imageInspectPattern() async throws {
        try await withRegexRouter { app in
            try app.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/json") { req in
                let imageName = req.parameters.get("name")
                let version = req.parameters.get("version")
                #expect(imageName != nil)
                return "Image: \(imageName ?? "unknown"), Version: \(version ?? "none")"
            }
        }
    }

    @Test
    func fallbackRouteInstallation() async throws {
        let app = try await makeApp()
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        try app.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/json") { _ in "" }

        let routeCount = app.routes.all.count
        try app.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/history") { _ in "" }

        // The second route adds only its native versioned and unversioned forms.
        #expect(app.routes.all.count == routeCount + 2)
        #expect(regexRouter.fallbackRoutePrefixes == ["images"])

        try await app.asyncShutdown()
    }

    @Test
    func invalidDockerPatternsThrowErrors() async throws {
        try await withRegexRouter { app in
            for pattern in ["containers/{id}", "/containers/{id", "/containers/{id:[0-9]+}"] {
                #expect(throws: Error.self) {
                    try app.registerVersionedRoute(.GET, pattern: pattern) { _ in "test" }
                }
            }
        }
    }

    @Test
    func greedyPluginNameSupportsSlashes() async throws {
        try await withRegexRouter { app in
            try app.registerVersionedRoute(.GET, pattern: "/plugins/{name:.*}/json") { request in
                request.parameters.get("name") ?? ""
            }

            for path in ["/plugins/vendor/plugin/json", "/v1.51/plugins/vendor/plugin/json"] {
                try await app.testing().test(.GET, path) { response async throws in
                    #expect(response.status == .ok)
                    #expect(response.body.string == "vendor/plugin")
                }
            }
        }
    }

    @Test
    func apiVersionUsesASCIIDigits() async throws {
        try await withRegexRouter { app in
            try app.registerVersionedRoute(.GET, pattern: "/_ping") { _ in "OK" }

            for path in ["/v١.٥١/_ping", "/v1.51.0/_ping", "/v1./_ping"] {
                try await app.testing().test(.GET, path) { response async throws in
                    #expect(response.status == .notFound)
                }
            }
        }
    }

    @Test
    func versionParameterExtractionWithVersion() async throws {
        try await withRegexRouter { app in
            // Register a route that returns the parameters as JSON so we can verify them
            try app.registerVersionedRoute(.GET, pattern: "/test-images/{name:.*}/inspect") { req in
                let version = req.parameters.get("version") ?? ""
                let name = req.parameters.get("name") ?? ""

                return [
                    "version": version,
                    "name": name,
                ]
            }

            // Test versioned URL - /v1.23/test-images/hello-world/inspect
            try await app.testing().test(.GET, "/v1.23/test-images/hello-world/inspect") { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode([String: String].self)
                #expect(response["version"] == "1.23")
                #expect(response["name"] == "hello-world")
            }
        }
    }

    @Test
    func versionParameterExtractionWithoutVersion() async throws {
        try await withRegexRouter { app in
            // Register a route that returns the parameters as JSON so we can verify them
            try app.registerVersionedRoute(.GET, pattern: "/test-images/{name:.*}/inspect") { req in
                let version = req.parameters.get("version") ?? ""
                let name = req.parameters.get("name") ?? ""

                return [
                    "version": version,
                    "name": name,
                ]
            }

            // Test non-versioned URL - /test-images/alpine/inspect
            try await app.testing().test(.GET, "/test-images/alpine/inspect") { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode([String: String].self)
                #expect(response["version"] == "")  // Empty version for missing optional group
                #expect(response["name"] == "alpine")
            }
        }
    }

    @Test
    func versionParameterExtractionWithComplexImageName() async throws {
        try await withRegexRouter { app in
            // Register a route that returns the parameters as JSON so we can verify them
            try app.registerVersionedRoute(.GET, pattern: "/test-images/{name:.*}/inspect") { req in
                let version = req.parameters.get("version") ?? ""
                let name = req.parameters.get("name") ?? ""

                return [
                    "version": version,
                    "name": name,
                ]
            }

            // Test complex image name with registry and digest
            try await app.testing().test(.GET, "/v2.0/test-images/quay.io/podman/hello@sha256:41316c18917a27a359ee3191fd8f43559d30592f82a144bbc59d9d44790f6e7a/inspect") {
                res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode([String: String].self)
                #expect(response["version"] == "2.0")
                #expect(response["name"] == "quay.io/podman/hello@sha256:41316c18917a27a359ee3191fd8f43559d30592f82a144bbc59d9d44790f6e7a")
            }
        }
    }

    @Test
    func multipleParametersExtractionWithVersion() async throws {
        try await withRegexRouter { app in
            // Register a route with multiple parameters
            try app.registerVersionedRoute(.GET, pattern: "/test-containers/{id}/action") { req in
                let version = req.parameters.get("version") ?? ""
                let id = req.parameters.get("id") ?? ""

                return [
                    "version": version,
                    "id": id,
                ]
            }

            // Test versioned container action
            try await app.testing().test(.GET, "/v1.41/test-containers/my-container/action") { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode([String: String].self)
                #expect(response["version"] == "1.41")
                #expect(response["id"] == "my-container")
            }
        }
    }

    @Test
    func multipleParametersExtractionWithoutVersion() async throws {
        try await withRegexRouter { app in
            // Register a route with multiple parameters
            try app.registerVersionedRoute(.GET, pattern: "/test-containers/{id}/action") { req in
                let version = req.parameters.get("version") ?? ""
                let id = req.parameters.get("id") ?? ""

                return [
                    "version": version,
                    "id": id,
                ]
            }

            // Test non-versioned container action
            try await app.testing().test(.GET, "/test-containers/test-container/action") { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode([String: String].self)
                #expect(response["version"] == "")  // Empty for missing version
                #expect(response["id"] == "test-container")
            }
        }
    }

}
