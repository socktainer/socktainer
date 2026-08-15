import Foundation
import Vapor

extension RoutesBuilder {
    var app: Application {
        self as! Application
    }

    /// Registers both the unversioned and `/vX.Y` Docker API forms.
    ///
    /// Vapor's trie handles the common single-segment form of every route.
    /// Moby patterns with a greedy parameter also register a scoped fallback
    /// for identifiers that contain a slash.
    func registerVersionedRoute<T: AsyncResponseEncodable & Sendable>(
        _ method: HTTPMethod,
        pattern: String,
        use closure: @escaping @Sendable (Request) async throws -> T
    ) throws {
        let dockerPattern = try DockerRoutePattern(pattern)
        let path = dockerPattern.pathComponents
        self.on(method, path, use: closure)
        self.on(method, [.parameter("version")] + path) { request async throws -> T in
            guard let component = request.parameters.get("version"),
                let version = DockerAPIVersionPath.parse(component)
            else {
                throw Abort(.notFound)
            }
            request.parameters.set("version", to: version)
            return try await closure(request)
        }

        if dockerPattern.hasGreedyParameter {
            try app.regexRouter.register(method, pattern: dockerPattern, use: closure)
            app.regexRouter.installFallbackRoutes(
                for: method,
                prefix: dockerPattern.literalPrefix,
                on: app
            )
        }
    }
}

private enum DockerRouteSegment {
    case constant(String)
    case parameter(name: String, constraint: String?)
}

private struct DockerRoutePattern {
    let segments: [DockerRouteSegment]

    init(_ pattern: String) throws {
        guard pattern.first == "/" else {
            throw Abort(.internalServerError, reason: "Docker route must start with '/': \(pattern)")
        }

        let rawSegments = pattern.split(separator: "/").map(String.init)
        guard !rawSegments.isEmpty else {
            throw Abort(.internalServerError, reason: "Docker route must have a literal prefix: \(pattern)")
        }
        self.segments = try rawSegments.map { raw in
            let startsParameter = raw.first == "{"
            let endsParameter = raw.last == "}"
            guard startsParameter == endsParameter else {
                throw Abort(.internalServerError, reason: "Malformed Docker route parameter: \(pattern)")
            }
            guard startsParameter else {
                guard !raw.contains("{") && !raw.contains("}") else {
                    throw Abort(.internalServerError, reason: "Malformed Docker route parameter: \(pattern)")
                }
                return .constant(raw)
            }

            let body = raw.dropFirst().dropLast()
            let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first, !name.isEmpty else {
                throw Abort(.internalServerError, reason: "Docker route parameter needs a name: \(pattern)")
            }
            let constraint = parts.count == 2 ? String(parts[1]) : nil
            guard constraint == nil || constraint == ".*" || constraint == ".+" else {
                throw Abort(.internalServerError, reason: "Unsupported Docker route constraint: \(pattern)")
            }
            return .parameter(name: String(name), constraint: constraint)
        }

        guard case .constant = segments[0] else {
            throw Abort(.internalServerError, reason: "Docker route must have a literal prefix: \(pattern)")
        }
    }

    var pathComponents: [PathComponent] {
        segments.map { segment in
            switch segment {
            case .constant(let value):
                return .constant(value)
            case .parameter(let name, _):
                return .parameter(name)
            }
        }
    }

    var hasGreedyParameter: Bool {
        segments.contains { segment in
            if case .parameter(_, .some) = segment { return true }
            return false
        }
    }

    var literalPrefix: String {
        guard case .constant(let value) = segments[0] else { fatalError("validated literal prefix") }
        return value
    }

    var regex: String {
        let suffix = segments.map { segment in
            switch segment {
            case .constant(let value):
                return "/" + NSRegularExpression.escapedPattern(for: value)
            case .parameter(_, let constraint):
                return constraint == ".*" ? "/(.*)" : "/(.+)"
            }
        }.joined()
        return "^(?:/v([0-9]+\\.[0-9]+))?" + suffix + "$"
    }

    var parameterNames: [String] {
        ["version"]
            + segments.compactMap { segment in
                guard case .parameter(let name, _) = segment else { return nil }
                return name
            }
    }
}

private enum DockerAPIVersionPath {
    static func parse(_ component: String) -> String? {
        guard component.first == "v" else { return nil }
        let version = component.dropFirst()
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
            parts.allSatisfy({ part in
                !part.isEmpty && part.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
            })
        else { return nil }
        return String(version)
    }
}

private struct RegexRoute {
    let method: HTTPMethod
    let regex: NSRegularExpression
    let handler: @Sendable (Request, [String]) async throws -> Response
}

private struct FallbackRouteKey: Hashable {
    let method: String
    let prefix: String
}

/// Fallback for Docker identifiers that contain slashes.
final class RegexRouter: @unchecked Sendable {
    private var routes: [RegexRoute] = []
    private var installedFallbacks: Set<FallbackRouteKey> = []
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    var fallbackRouteCount: Int {
        routes.count
    }

    var fallbackRoutePrefixes: Set<String> {
        Set(installedFallbacks.map(\.prefix))
    }

    fileprivate func register<T: AsyncResponseEncodable & Sendable>(
        _ method: HTTPMethod,
        pattern: DockerRoutePattern,
        use closure: @escaping @Sendable (Request) async throws -> T
    ) throws {
        let regex = try NSRegularExpression(pattern: pattern.regex)
        logger.debug(
            "RegexRouter: registering greedy Docker route",
            metadata: ["method": "\(method.rawValue)", "pattern": "\(pattern.regex)"]
        )
        let parameterNames = pattern.parameterNames
        let handler: @Sendable (Request, [String]) async throws -> Response = { request, groups in
            for (index, name) in parameterNames.enumerated() where index < groups.count {
                if !groups[index].isEmpty {
                    request.parameters.set(name, to: groups[index])
                }
            }
            return try await closure(request).encodeResponse(for: request)
        }
        routes.append(RegexRoute(method: method, regex: regex, handler: handler))
    }

    func installFallbackRoutes(for method: HTTPMethod, prefix: String, on app: Application) {
        let key = FallbackRouteKey(method: method.rawValue, prefix: prefix)
        guard installedFallbacks.insert(key).inserted else { return }

        app.on(method, [.constant(prefix), .catchall]) { [self] request async throws -> Response in
            try await route(request)
        }
        app.on(method, [.parameter("version"), .constant(prefix), .catchall]) {
            [self] request async throws -> Response in
            try await route(request)
        }
    }

    private func route(_ request: Request) async throws -> Response {
        let path = request.url.path
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        for route in routes where route.method == request.method {
            guard let match = route.regex.firstMatch(in: path, range: range) else { continue }
            let groups = (1..<match.numberOfRanges).map { index -> String in
                guard let range = Range(match.range(at: index), in: path) else { return "" }
                return String(path[range])
            }
            return try await route.handler(request, groups)
        }
        throw Abort(.notFound)
    }
}

private struct RegexRouterKey: StorageKey {
    typealias Value = RegexRouter
}

extension Application {
    var regexRouter: RegexRouter {
        guard let stored = storage[RegexRouterKey.self] else {
            fatalError("RegexRouter must be configured before Docker routes are registered")
        }
        return stored
    }

    func setRegexRouter(_ router: RegexRouter) {
        storage[RegexRouterKey.self] = router
    }

    func regexRouter(with logger: Logger) -> RegexRouter {
        RegexRouter(logger: logger)
    }
}
