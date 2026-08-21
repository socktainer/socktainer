import Vapor

struct LibpodVersionRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/version", use: LibpodVersionRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        let version = LibpodVersionInfo(
            APIVersion: getDockerEngineApiMaxVersion(),
            Arch: "arm64",
            BuildTime: getBuildTime(),
            GitCommit: getBuildGitCommit(),
            GoVersion: "N/A",
            MinAPIVersion: getDockerEngineApiMinVersion(),
            Os: "linux",
            Version: getBuildVersion()
        )
        return try await version.encodeResponse(for: req)
    }
}
