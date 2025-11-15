import Vapor

struct VersionRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/version", use: VersionRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        do {
            let version = VersionInfo(
                Platform: ServerPlatform(Name: "socktainer"),
                // NOTE: For the time being, we will report socktainer's version as a component
                //       https://github.com/socktainer/socktainer/pull/28#issuecomment-3318209340
                Components: [Component(Name: "socktainer", Version: getBuildVersion())],
                // NOTE: Some libraries may require a higher SemVer version compared to Socktainer's actual version
                //       https://github.com/testcontainers/testcontainers-java/blob/51219646dca72ad267e575bf25d0b60208c60b42/core/src/main/java/org/testcontainers/DockerClientFactory.java#L272
                //       As a workaround, set the version as the highest supported Docker Engine API version
                Version: getDockerEngineApiMaxVersion(),
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
