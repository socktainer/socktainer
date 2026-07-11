import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private struct FakeSearchProvider: ImageSearchProviding {
    let results: [DockerHubSearchResult]
    func search(term: String, limit: Int) async throws -> [DockerHubSearchResult] { results }
}

private let hubResults = [
    DockerHubSearchResult(star_count: 11_000, is_official: true, name: "nginx", is_automated: false, description: "Official build of Nginx."),
    DockerHubSearchResult(star_count: 250, is_official: false, name: "bitnami/nginx", is_automated: true, description: "Bitnami nginx"),
    DockerHubSearchResult(star_count: nil, is_official: nil, name: "someone/nginx-fork", is_automated: nil, description: nil),
]

private func withSearchApp(_ provider: FakeSearchProvider, run: (Application) async throws -> Void) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
        try app.register(collection: ImageSearchRoute(searchProvider: provider))
        try await run(app)
    }
}

@Suite("ImageSearchRoute")
struct ImageSearchRouteTests {

    @Test("returns Moby-shaped results with defaults for missing Hub fields")
    func returnsResults() async throws {
        try await withSearchApp(FakeSearchProvider(results: hubResults)) { app in
            try await app.testing().test(.GET, "/v1.51/images/search?term=nginx") { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([RESTImageSearchResult].self)
                #expect(body.count == 3)
                #expect(body[0].name == "nginx")
                #expect(body[0].is_official)
                #expect(body[2].star_count == 0)
                #expect(body[2].description == "")
            }
        }
    }

    @Test("a missing term answers 400")
    func missingTerm() async throws {
        try await withSearchApp(FakeSearchProvider(results: [])) { app in
            try await app.testing().test(.GET, "/v1.51/images/search") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("limits outside 1...100 answer 400, like moby")
    func invalidLimit() async throws {
        try await withSearchApp(FakeSearchProvider(results: [])) { app in
            try await app.testing().test(.GET, "/v1.51/images/search?term=nginx&limit=0") { res async in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.GET, "/v1.51/images/search?term=nginx&limit=101") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("is-official and stars filters narrow the results")
    func filters() async throws {
        let all = hubResults.map(ImageSearchRoute.restResult)

        let official = try ImageSearchRoute.apply(filters: ["is-official": ["true"]], to: all)
        #expect(official.map(\.name) == ["nginx"])

        let starred = try ImageSearchRoute.apply(filters: ["stars": ["100"]], to: all)
        #expect(starred.map(\.name) == ["nginx", "bitnami/nginx"])

        let automated = try ImageSearchRoute.apply(filters: ["is-automated": ["true"]], to: all)
        #expect(automated.map(\.name) == ["bitnami/nginx"])
    }

    @Test("invalid filter values are rejected instead of silently ignored")
    func invalidFilterValues() throws {
        let all = hubResults.map(ImageSearchRoute.restResult)

        #expect(throws: Abort.self) {
            try ImageSearchRoute.apply(filters: ["stars": ["abc"]], to: all)
        }
        #expect(throws: Abort.self) {
            try ImageSearchRoute.apply(filters: ["is-official": ["maybe"]], to: all)
        }
        #expect(throws: Abort.self) {
            try ImageSearchRoute.apply(filters: ["is-official": ["false", "true"]], to: all)
        }
    }

    @Test("multiple stars values apply the strongest bound")
    func multipleStarsValues() throws {
        let all = hubResults.map(ImageSearchRoute.restResult)
        let filtered = try ImageSearchRoute.apply(filters: ["stars": ["100", "1000"]], to: all)
        #expect(filtered.map(\.name) == ["nginx"])
    }

    @Test("boolean filter values accept Go's ParseBool spellings")
    func parseBoolSpellings() throws {
        let all = hubResults.map(ImageSearchRoute.restResult)
        for spelling in ["1", "t", "T", "TRUE", "true", "True"] {
            let filtered = try ImageSearchRoute.apply(filters: ["is-official": [spelling]], to: all)
            #expect(filtered.map(\.name) == ["nginx"], "spelling \(spelling)")
        }
        #expect(MobyBool.parse("False") == false)
        #expect(MobyBool.parse("yes") == nil)
    }

    @Test("registry-qualified terms are rejected: only Docker Hub is searchable")
    func registryQualifiedTerm() async throws {
        #expect(ImageSearchRoute.registryQualifier(of: "quay.io/podman") == "quay.io")
        #expect(ImageSearchRoute.registryQualifier(of: "localhost:5000/img") == "localhost:5000")
        #expect(ImageSearchRoute.registryQualifier(of: "bitnami/nginx") == nil)
        #expect(ImageSearchRoute.registryQualifier(of: "nginx") == nil)

        try await withSearchApp(FakeSearchProvider(results: [])) { app in
            try await app.testing().test(.GET, "/v1.51/images/search?term=quay.io%2Fpodman") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("the docker CLI's map-encoded filters are accepted")
    func mapEncodedFilters() throws {
        let parsed = try ImageSearchRoute.parseFilters(#"{"is-official":{"true":true},"stars":{"100":true}}"#)
        #expect(parsed["is-official"] == ["true"])
        #expect(parsed["stars"] == ["100"])
    }

    @Test("unknown filter keys answer 400")
    func unknownFilter() async throws {
        try await withSearchApp(FakeSearchProvider(results: [])) { app in
            try await app.testing().test(
                .GET, "/v1.51/images/search?term=nginx&filters=%7B%22label%22%3A%5B%22x%22%5D%7D"
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("the Hub URL carries the encoded term and limit")
    func urlBuilding() {
        let url = ImageSearchRoute.searchURL(term: "web app", limit: 3)
        #expect(url.absoluteString == "https://index.docker.io/v1/search?q=web%20app&n=3")
    }

    @Test("the default limit is moby's 25")
    func defaultLimit() throws {
        #expect(try ImageSearchRoute.validatedLimit(nil) == 25)
        #expect(try ImageSearchRoute.validatedLimit(100) == 100)
    }
}
