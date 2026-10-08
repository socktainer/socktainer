import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression for issue #415: `POST /build` ignored a build context sent with
/// `Content-Length` (Docker Python SDK) because it only read the body when it
/// was already collected or `Transfer-Encoding: chunked`. Over a real socket a
/// RegexRouter route receives a streamed body, so the in-memory tester (which
/// delivers a collected body) cannot reproduce it — a live server is used.
@Suite("BuildRoute — build context body")
struct BuildContextBodyTests {

    @Test("a Content-Length build context is extracted with its Dockerfile")
    func contentLengthBodyIsReceived() async throws {
        let dockerfile = "FROM scratch\n"
        let tar = try makeContextTar(dockerfile: dockerfile)
        try await withBuildBodyApp { app, tempContextDir in
            try await app.testing(method: .running(hostname: "127.0.0.1", port: 0)).test(
                .POST, "/v1.51/probe",
                headers: ["Content-Type": "application/x-tar", "Content-Length": "\(tar.count)"],
                body: ByteBuffer(data: tar)
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == tempContextDir.appendingPathComponent("context").path)
            }
            let extracted = tempContextDir.appendingPathComponent("context/Dockerfile")
            #expect(try String(contentsOf: extracted, encoding: .utf8) == dockerfile)
        }
    }

    @Test("an empty body falls back to no context and removes the temporary directory")
    func emptyBodyIsZero() async throws {
        try await withBuildBodyApp { app, tempContextDir in
            try await app.testing(method: .running(hostname: "127.0.0.1", port: 0)).test(
                .POST, "/v1.51/probe"
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == ".")
            }
            #expect(!FileManager.default.fileExists(atPath: tempContextDir.path))
        }
    }
}

// MARK: - Helpers

private func withBuildBodyApp(
    test: @escaping (Application, URL) async throws -> Void
) async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let tempContextDir = tmp.appendingPathComponent("build")

    try await withApp(configure: { app in
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
    }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.registerVersionedRoute(.POST, pattern: "/probe") { req async throws -> String in
            try await BuildRoute.prepareBuildContext(req, in: tempContextDir)
        }
        try await test(app, tempContextDir)
    }
}

private func makeContextTar(dockerfile: String) throws -> Data {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = dir.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(dockerfile.utf8).write(to: source.appendingPathComponent("Dockerfile"))
    let tarPath = dir.appendingPathComponent("context.tar")
    try ArchiveUtility.create(tarPath: tarPath, from: source)
    return try Data(contentsOf: tarPath)
}
