import Vapor

struct LibpodCommitRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/commit", use: CommitRoute.handler)
    }
}
