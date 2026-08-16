import Vapor

enum DockerPing {
    static let apiVersion: String = {
        let value = getDockerEngineApiMaxVersion()
        return value.hasPrefix("v") ? String(value.dropFirst()) : value
    }()

    static func matches(method: HTTPMethod, path: String) -> Bool {
        guard method == .GET || method == .HEAD else { return false }
        let components = path.split(separator: "/")
        guard components.last == "_ping" else { return false }
        if components.count == 1 { return true }
        guard components.count == 2, components[0].first == "v" else { return false }
        let versionParts = components[0].dropFirst().split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return versionParts.count == 2
            && versionParts.allSatisfy {
                !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
            }
    }

    static func response(includeBody: Bool) -> Response {
        let response = Response(status: .ok)
        if includeBody { response.body = .init(string: "OK") }
        response.headers.add(name: "Api-Version", value: apiVersion)
        response.headers.add(name: "Builder-Version", value: "")
        response.headers.add(name: "Docker-Experimental", value: "false")
        response.headers.add(name: "Cache-Control", value: "no-cache, no-store, must-revalidate")
        response.headers.add(name: "Pragma", value: "no-cache")
        return response
    }
}

struct DockerPingResponder: Responder {
    let next: any Responder

    func respond(to request: Request) -> EventLoopFuture<Response> {
        guard DockerPing.matches(method: request.method, path: request.url.path) else {
            return next.respond(to: request)
        }
        return request.eventLoop.makeSucceededFuture(
            DockerPing.response(includeBody: request.method == .GET)
        )
    }
}
