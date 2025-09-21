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
                // NOTE: Empty for the time being, could be populated with additional information
                Components: [],
                Version: getBuildVersion(),
                ApiVersion: getDockerEngineApiMaxVersion(),
                MinAPIVersion: getDockerEngineApiMinVersion(),
                GitCommit: getBuildGitCommit(),
                Os: "macOS",
                Arch: "arm64",
                KernelVersion: getKernel(),
                Experimental: true,
                BuildTime: getBuildTime(),
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
