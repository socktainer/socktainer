import Vapor

struct VersionRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "version", use: VersionRoute.handler)
        // also handle without version prefix
        routes.get("version", use: VersionRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        do {
            let version = VersionInfo(
                Platform: ServerPlatform(Name: "socktainer"),
                Components: [],
                Version: ProcessInfo.processInfo.environment["SOCKTAINER_VERSION"] ?? "unknown",
                ApiVersion: "v1.51",
                MinAPIVersion: "v1.51",
                GitCommit: ProcessInfo.processInfo.environment["GIT_COMMIT"] ?? "unknown",
                Os: "macOS",
                Arch: "arm64",
                KernelVersion: getKernel(),
                Experimental: isDebug(),
                BuildTime: ProcessInfo.processInfo.environment["SOCKTAINER_BUILD_TIME"] ?? "unknown",
            )
            return try await version.encodeResponse(for: req)
        } catch {
            let response = Response(status: .internalServerError)
            response.headers.add(name: .contentType, value: "application/json")
            response.body = .init(string: "{\"message\": \"Failed to generate version information\"}\n")
            return response
        }
    }
}
