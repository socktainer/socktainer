import Foundation
import Vapor

extension RoutesBuilder {
    var app: Application {
        self as! Application
    }

    func registerVersionedRoute<T: AsyncResponseEncodable & Sendable>(
        _ method: HTTPMethod,
        pattern: String,
        use closure: @escaping @Sendable (Request) async throws -> T
    ) throws {
        try app.regexRouter.register(method, pattern: pattern, use: closure)
    }
}

struct RegexRoute {
    let method: HTTPMethod
    let regex: NSRegularExpression
    let handler: @Sendable (Request, [String]) async throws -> Response
    /// Precomputed at registration time (the pattern never changes afterward) so per-request
    /// matching doesn't rescan every candidate's pattern string on every incoming request.
    /// See `RegexRoutingMiddleware.respond` for how this ranks competing matches. Callers
    /// derive these from the original route TEMPLATE (before `{param}` -> regex conversion,
    /// see `RegexRouter.templateSpecificity`) rather than the compiled regex pattern string —
    /// the compiled pattern's length/slash-count can vary with parameter name length or regex
    /// boilerplate (anchors, the optional version prefix) in ways that don't reflect the
    /// route's actual literal structure.
    let specificitySlashes: Int
    let specificityLength: Int

    init(
        method: HTTPMethod, regex: NSRegularExpression, handler: @escaping @Sendable (Request, [String]) async throws -> Response,
        specificitySlashes: Int, specificityLength: Int
    ) {
        self.method = method
        self.regex = regex
        self.handler = handler
        self.specificitySlashes = specificitySlashes
        self.specificityLength = specificityLength
    }
}

final class RegexRouter: @unchecked Sendable {
    fileprivate var routes: [RegexRoute] = []
    private var middlewareInstalled = false
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func register(
        _ method: HTTPMethod, pattern: String,
        handler: @escaping @Sendable (Request, [String]) async throws -> Response
    ) throws {
        let regex = try NSRegularExpression(pattern: pattern)
        let (slashes, length) = Self.templateSpecificity(pattern)
        insertSorted(RegexRoute(method: method, regex: regex, handler: handler, specificitySlashes: slashes, specificityLength: length))
    }

    func register<T: AsyncResponseEncodable & Sendable>(
        _ method: HTTPMethod, pattern: String,
        use closure: @escaping @Sendable (Request) async throws -> T
    ) throws {
        // Convert Moby/Docker API pattern like "/images/{name:.*}/json" to regex
        let (regexPattern, parameterNames) = convertMobyRoutePatternToRegex(pattern)
        let regex = try NSRegularExpression(pattern: regexPattern)

        // Log registration details using instance logger
        logger.debug("RegexRouter: Registering \(method.rawValue) route - Pattern: '\(pattern)' -> Regex: '\(regexPattern)' with parameters: \(parameterNames)")

        let handler: @Sendable (Request, [String]) async throws -> Response = { req, groups in
            req.logger.debug("RegexRouter: Setting parameters from groups: \(groups) with names: \(parameterNames)")

            // Set parameters based on captured groups and their names
            for (index, paramName) in parameterNames.enumerated() {
                if index < groups.count {
                    let value = groups[index]
                    // Only set parameter if the captured value is not empty
                    if !value.isEmpty {
                        req.parameters.set(paramName, to: value)
                        req.logger.debug("RegexRouter: Set parameter '\(paramName)' = '\(value)'")

                        // Log version parameter specifically for debugging
                        if paramName == "version" {
                            req.logger.debug("RegexRouter: API version found in URL: v\(value)")
                        }
                    }
                }
            }
            let result = try await closure(req)
            return try await result.encodeResponse(for: req)
        }

        let specificity = Self.templateSpecificity(pattern)
        insertSorted(
            RegexRoute(
                method: method, regex: regex, handler: handler,
                specificitySlashes: specificity.slashes, specificityLength: specificity.length))
    }

    /// Computes route specificity from the ORIGINAL route template (e.g.
    /// `/libpod/manifests/{name}/registry/{destination}`), before `{param}` placeholders are
    /// converted to regex capture groups — see `RegexRoute.specificitySlashes` for why this
    /// must come from the template rather than the compiled regex pattern. Placeholders are
    /// collapsed to a single marker character first so two routes differing only in parameter
    /// name length (e.g. `{name}` vs `{destination}`) don't spuriously compare as differently
    /// specific.
    private static func templateSpecificity(_ pattern: String) -> (slashes: Int, length: Int) {
        let placeholderRegex = try! NSRegularExpression(pattern: #"\{[^}]*\}"#)
        let normalized = placeholderRegex.stringByReplacingMatches(
            in: pattern, range: NSRange(location: 0, length: pattern.utf16.count), withTemplate: "\u{2022}")
        let slashes = normalized.filter { $0 == "/" }.count
        return (slashes, normalized.count)
    }

    /// Inserts `route` keeping `routes` ordered by descending specificity (most literal
    /// `/` characters, then longest pattern, ties broken by registration order) — see
    /// `RegexRoutingMiddleware.respond` for why match order matters. Registration only
    /// happens a fixed, small number of times at startup, so re-deriving the sorted
    /// position per insert is cheap; every per-request match then gets to short-circuit
    /// on the first hit instead of scanning every candidate.
    private func insertSorted(_ route: RegexRoute) {
        let index = routes.firstIndex { existing in
            if existing.specificitySlashes != route.specificitySlashes {
                return existing.specificitySlashes < route.specificitySlashes
            }
            return existing.specificityLength < route.specificityLength
        }
        routes.insert(route, at: index ?? routes.count)
    }

    private func convertMobyRoutePatternToRegex(_ pattern: String) -> (regex: String, parameterNames: [String]) {
        var regexPattern = pattern
        var parameterNames: [String] = []

        // Add version parameter as first capture group (optional)
        parameterNames.append("version")

        // Find all parameters like {paramName:.*} or {paramName}
        let parameterRegex = try! NSRegularExpression(pattern: #"\{([^:}]+)(?::[^}]*)?\}"#)
        let matches = parameterRegex.matches(in: pattern, range: NSRange(location: 0, length: pattern.count))

        // Extract parameter names in order (after version)
        for match in matches {
            let paramNameRange = match.range(at: 1)
            let paramName = (pattern as NSString).substring(with: paramNameRange)
            parameterNames.append(paramName)
        }

        // Replace all parameter patterns with capture groups
        regexPattern = parameterRegex.stringByReplacingMatches(
            in: regexPattern,
            range: NSRange(location: 0, length: regexPattern.count),
            withTemplate: "(.+)"
        )

        // Add optional version prefix: /v1.47/images/... or /images/...
        // Group 1: version (e.g., "1.47")
        // Group 2+: original parameters
        regexPattern = "^(?:/v([0-9]+\\.[0-9]+(?:\\.[0-9]+)?))?" + regexPattern + "$"

        return (regexPattern, parameterNames)
    }

    func installMiddleware(on app: Application) {
        guard !middlewareInstalled else { return }
        app.middleware.use(RegexRoutingMiddleware(regexRouter: self))
        middlewareInstalled = true
    }
}

struct RegexRoutingMiddleware: Middleware {
    let regexRouter: RegexRouter

    func respond(to request: Request, chainingTo next: Responder) -> EventLoopFuture<Response> {
        let path = request.url.path

        request.logger.debug("RegexRouter: Checking path '\(path)' against \(regexRouter.routes.count) registered routes")

        let range = NSRange(location: 0, length: path.utf16.count)
        // A route's pattern is a fixed string (not path components), so match specificity
        // can't be judged by "path segment count" the way most routers do it. Instead:
        // `routes` is kept sorted (see `RegexRouter.insertSorted`) by descending literal
        // `/` count in the pattern, then pattern length — a route like
        // `/libpod/manifests/{name}/registry/{destination}` has strictly more literal
        // structure around its wildcards than the bare `/libpod/manifests/{name}`, so it
        // sorts earlier and is tried first. Without this, a greedy `.+` wildcard in a
        // less-specific route (e.g. manifest create's `{name:.*}`) matches ANY longer path
        // first-registered-wins, silently swallowing requests meant for a more specific
        // sibling route registered later (e.g. manifest push's `{name}/registry/{destination}`,
        // whose full destination ends up captured as part of "name" instead). Iterating in
        // that pre-sorted order lets this short-circuit on the first (most specific) match
        // instead of evaluating every candidate on every request.
        for route in regexRouter.routes where route.method == request.method {
            request.logger.debug("RegexRouter: Testing regex pattern '\(route.regex.pattern)' against path '\(path)'")
            guard let match = route.regex.firstMatch(in: path, range: range) else { continue }

            let groups = (1..<match.numberOfRanges).map { groupIndex -> String in
                let range = match.range(at: groupIndex)
                // Check if the range is valid (NSNotFound indicates no match for optional groups)
                guard range.location != NSNotFound else { return "" }
                let raw = (path as NSString).substring(with: range)
                // `request.url.path` is still percent-encoded (Vapor's `URI.path` only
                // unescapes a literal `%3B`), so a `.*`-style segment containing an
                // encoded `/` (e.g. `docker://192.168.1.1:5000/repo:tag` path-encoded
                // as `.../registry/192.168.1.1:5000%2Frepo:tag`, real podman's manifest
                // push destination form) would otherwise reach the handler with a
                // literal `%2F` still in it instead of a real slash.
                return raw.removingPercentEncoding ?? raw
            }

            request.logger.debug("RegexRouter: MATCHED! pattern='\(route.regex.pattern)' Captured groups: \(groups)")

            let promise = request.eventLoop.makePromise(of: Response.self)
            promise.completeWithTask {
                try await route.handler(request, groups)
            }
            return promise.futureResult
        }

        request.logger.debug("RegexRouter: No regex routes matched, passing to next middleware")
        return next.respond(to: request)
    }
}

private struct RegexRouterKey: StorageKey {
    typealias Value = RegexRouter
}

extension Application {
    var regexRouter: RegexRouter {
        guard let stored = self.storage[RegexRouterKey.self] else {
            fatalError("RegexRouter must be configured with a logger. Call app.setRegexRouter() in configure.swift")
        }
        return stored
    }

    func setRegexRouter(_ router: RegexRouter) {
        self.storage[RegexRouterKey.self] = router
    }

    func regexRouter(with logger: Logger) -> RegexRouter {
        RegexRouter(logger: logger)
    }
}
