import Foundation
import Vapor

struct RESTImageSearchResult: Content {
    let star_count: Int
    let is_official: Bool
    let name: String
    let is_automated: Bool
    let description: String
}

struct DockerHubSearchResponse: Codable, Sendable {
    let results: [DockerHubSearchResult]
}

struct DockerHubSearchResult: Codable, Sendable {
    let star_count: Int?
    let is_official: Bool?
    let name: String
    let is_automated: Bool?
    let description: String?
}

protocol ImageSearchProviding: Sendable {
    func search(term: String, limit: Int) async throws -> [DockerHubSearchResult]
}

/// moby proxies `docker search` to the index server's v1 search endpoint and
/// filters the results daemon-side — same contract here, against Docker Hub.
struct DockerHubSearchProvider: ImageSearchProviding {
    func search(term: String, limit: Int) async throws -> [DockerHubSearchResult] {
        let url = ImageSearchRoute.searchURL(term: term, limit: limit)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Abort(.internalServerError, reason: "cannot reach index.docker.io: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw Abort(.internalServerError, reason: "registry search failed: index.docker.io answered HTTP \(status)")
        }
        do {
            return try JSONDecoder().decode(DockerHubSearchResponse.self, from: data).results
        } catch {
            throw Abort(.internalServerError, reason: "registry search failed: unexpected response from index.docker.io")
        }
    }
}

struct ImageSearchRoute: RouteCollection {
    let searchProvider: ImageSearchProviding

    init(searchProvider: ImageSearchProviding = DockerHubSearchProvider()) {
        self.searchProvider = searchProvider
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/images/search", use: ImageSearchRoute.handler(searchProvider: searchProvider))
    }

    static func handler(searchProvider: ImageSearchProviding) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let term = try? req.query.get(String.self, at: "term"), !term.isEmpty else {
                throw Abort(.badRequest, reason: "term is required")
            }
            if let registry = registryQualifier(of: term) {
                throw Abort(.badRequest, reason: "searching registries other than Docker Hub is not supported (term references '\(registry)')")
            }
            let limit = try validatedLimit(req.query[Int.self, at: "limit"])
            let filters = try parseFilters(req.query[String.self, at: "filters"])

            let results = try await searchProvider.search(term: term, limit: limit)
            let response = try apply(filters: filters, to: results.map(restResult))
            return try await response.encodeResponse(status: .ok, for: req)
        }
    }

    /// moby rejects limits outside 1...100 (registry/search.go, v28.5.2) and
    /// defaults to 25 when the client sends none.
    static func validatedLimit(_ raw: Int?) throws -> Int {
        guard let raw else { return 25 }
        guard (1...100).contains(raw) else {
            throw Abort(.badRequest, reason: "limit \(raw) is outside the range of [1, 100]")
        }
        return raw
    }

    /// Docker clients encode filters either as lists ({"stars":["100"]}) or as
    /// value maps ({"stars":{"100":true}}) — the docker CLI sends the latter.
    static func parseFilters(_ raw: String?) throws -> [String: [String]] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return [:] }
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Abort(.badRequest, reason: "invalid filters: \(raw)")
        }
        let known: Set<String> = ["is-official", "is-automated", "stars"]
        var parsed: [String: [String]] = [:]
        for (key, value) in decoded {
            guard known.contains(key) else {
                throw Abort(.badRequest, reason: "invalid filter '\(key)'")
            }
            if let list = value as? [String] {
                parsed[key] = list
            } else if let map = value as? [String: Bool] {
                parsed[key] = map.filter { $0.value }.map { $0.key }.sorted()
            } else {
                throw Abort(.badRequest, reason: "invalid filter value for '\(key)'")
            }
        }
        return parsed
    }

    static func apply(filters: [String: [String]], to results: [RESTImageSearchResult]) throws -> [RESTImageSearchResult] {
        var filtered = results
        if let official = try boolValue(filters, key: "is-official") {
            filtered = filtered.filter { $0.is_official == official }
        }
        if let automated = try boolValue(filters, key: "is-automated") {
            filtered = filtered.filter { $0.is_automated == automated }
        }
        if let minStars = try minStarsValue(filters) {
            filtered = filtered.filter { $0.star_count >= minStars }
        }
        return filtered
    }

    static func boolValue(_ filters: [String: [String]], key: String) throws -> Bool? {
        guard let values = filters[key], !values.isEmpty else { return nil }
        let parsed = Set(
            try values.map { value -> Bool in
                guard let flag = MobyBool.parse(value) else {
                    throw Abort(.badRequest, reason: "invalid filter '\(key)=\(value)': must be true or false")
                }
                return flag
            })
        guard parsed.count == 1 else {
            throw Abort(.badRequest, reason: "invalid filter '\(key)': conflicting values")
        }
        return parsed.first
    }

    static func minStarsValue(_ filters: [String: [String]]) throws -> Int? {
        guard let values = filters["stars"], !values.isEmpty else { return nil }
        let parsed = try values.map { value -> Int in
            guard let stars = Int(value), stars >= 0 else {
                throw Abort(.badRequest, reason: "invalid filter 'stars=\(value)': must be a non-negative integer")
            }
            return stars
        }
        return parsed.max()
    }

    /// A term like `myregistry.example.com/image` targets a specific registry
    /// in moby; only Docker Hub is supported here, so such terms are rejected
    /// instead of returning confusing empty Hub matches. Same hostname
    /// heuristic as docker's reference splitting: the first path segment is a
    /// registry when it contains a dot, a colon, or is "localhost".
    static func registryQualifier(of term: String) -> String? {
        guard let slash = term.firstIndex(of: "/") else { return nil }
        let candidate = String(term[..<slash])
        guard candidate.contains(".") || candidate.contains(":") || candidate == "localhost" else { return nil }
        return candidate
    }

    static func searchURL(term: String, limit: Int) -> URL {
        var components = URLComponents(string: "https://index.docker.io/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "n", value: String(limit)),
        ]
        return components.url!
    }

    static func restResult(_ result: DockerHubSearchResult) -> RESTImageSearchResult {
        RESTImageSearchResult(
            star_count: result.star_count ?? 0,
            is_official: result.is_official ?? false,
            name: result.name,
            is_automated: result.is_automated ?? false,
            description: result.description ?? ""
        )
    }
}
