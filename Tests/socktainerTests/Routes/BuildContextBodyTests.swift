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

    @Test("a Content-Length build context is written to disk")
    func contentLengthBodyIsReceived() async throws {
        let payload = String(repeating: "A", count: 8_192)
        try await withBuildBodyApp { app, tarPath in
            try await app.testing(method: .running(hostname: "127.0.0.1", port: 0)).test(
                .POST, "/v1.51/probe",
                headers: ["Content-Type": "application/x-tar", "Content-Length": "\(payload.utf8.count)"],
                body: ByteBuffer(string: payload)
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "\(payload.utf8.count)")
            }
            #expect(try String(contentsOf: tarPath, encoding: .utf8) == payload)
        }
    }

    @Test("an empty body yields zero bytes (daemon falls back to no context)")
    func emptyBodyIsZero() async throws {
        try await withBuildBodyApp { app, _ in
            try await app.testing(method: .running(hostname: "127.0.0.1", port: 0)).test(
                .POST, "/v1.51/probe"
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "0")
            }
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
    let tarPath = tmp.appendingPathComponent("context.tar")

    try await withApp(configure: { app in
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
    }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.registerVersionedRoute(.POST, pattern: "/probe") { req async throws -> String in
            "\(try await BuildRoute.receiveBuildContext(req, into: tarPath))"
        }
        try await test(app, tarPath)
    }
}
