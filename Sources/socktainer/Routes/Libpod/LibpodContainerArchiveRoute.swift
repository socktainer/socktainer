import Foundation
import Vapor

struct LibpodContainerArchiveRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let archiveClient: ClientArchiveProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET,
            pattern: "/libpod/containers/{id:.*}/archive",
            use: Self.reportingResolvedPath(ContainerArchiveRoute.getHandler(containerClient: containerClient, archiveClient: archiveClient))
        )
        try routes.registerVersionedRoute(
            .PUT,
            pattern: "/libpod/containers/{id:.*}/archive",
            use: ContainerArchiveRoute.putHandler(containerClient: containerClient, archiveClient: archiveClient)
        )
        try routes.registerVersionedRoute(
            .HEAD,
            pattern: "/libpod/containers/{id:.*}/archive",
            use: Self.reportingResolvedPath(ContainerArchiveRoute.headHandler(containerClient: containerClient, archiveClient: archiveClient))
        )
    }

    static let statHeader = "X-Docker-Container-Path-Stat"

    /// podman's copy logic builds its destination from the stat's `linkTarget`, which for a path
    /// that is not a symlink is the path itself (moby leaves it empty). With it empty, podman
    /// derives `.` as the extraction directory and a `podman cp` into a container silently lands
    /// nowhere. It also needs `isDir` (see below).
    static func reportingResolvedPath(_ docker: @escaping LibpodAdapter.Handler) -> LibpodAdapter.Handler {
        { req in
            let response = try await docker(req)
            guard let encoded = response.headers.first(name: statHeader),
                let data = Data(base64Encoded: encoded),
                var stat = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let requested = req.query["path"] as String?
            else { return response }
            // podman's `FileInfo` carries `isDir` as its own field; moby's header only has the mode
            // (Go's `os.ModeDir` is bit 31), and without it podman treats a directory as a file.
            let mode = (stat["mode"] as? NSNumber)?.uint32Value ?? 0
            stat["isDir"] = mode & (1 << 31) != 0
            if (stat["linkTarget"] as? String ?? "").isEmpty {
                let absolute = requested.hasPrefix("/") ? requested : "/" + requested
                stat["linkTarget"] = absolute.count > 1 && absolute.hasSuffix("/") ? String(absolute.dropLast()) : absolute
            }
            if let updated = try? JSONSerialization.data(withJSONObject: stat) {
                response.headers.replaceOrAdd(name: statHeader, value: urlSafeBase64(updated))
            }
            return response
        }
    }

    /// podman decodes the stat header with Go's `base64.URLEncoding` (moby uses `StdEncoding`), so
    /// a payload whose encoding contains `+` or `/` would otherwise fail to decode.
    static func urlSafeBase64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
}
