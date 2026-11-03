import ContainerAPIClient
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Real podman's `ImagesImport` handler (`pkg/api/handlers/libpod/images.go`) writes a
/// single `{"Id": "<digest>"}` JSON object once the import completes — unlike Docker
/// compat's `/images/create`, which streams progress lines. A podman client can't parse
/// the latter, so this must not just forward the Docker route's response unchanged.
@Suite("LibpodImageImportRoute")
struct LibpodImageImportRouteTests {
    @Test("a successful import responds with {\"Id\": <digest>}, not the Docker progress stream")
    func successfulImportReturnsIdPayload() async throws {
        let client = SpyImageClient()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[AppleContainerAppSupportUrlKey.self] = FileManager.default.temporaryDirectory
            try app.register(collection: LibpodImageImportRoute(client: client))

            let body = ByteBuffer(repeating: 0xAA, count: 1024)
            try await app.testing().test(
                .POST, "/v1.51/libpod/images/import?reference=myimage:latest",
                body: body
            ) { res async throws in
                #expect(res.status == .ok)
                let decoded = try JSONDecoder().decode(LibpodImageImportRoute.RESTLibpodImportIDResponse.self, from: Data(buffer: res.body))
                #expect(decoded.Id == "sha256:" + String(repeating: "b", count: 64))
            }
        }
        #expect(await client.importImageWasCalled)
    }

    @Test("a digest reference is rejected without the body ever being read")
    func digestReferenceRejectedBeforeBodyIsRead() async throws {
        let client = SpyImageClient()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[AppleContainerAppSupportUrlKey.self] = FileManager.default.temporaryDirectory
            try app.register(collection: LibpodImageImportRoute(client: client))

            let hugeGarbageBody = ByteBuffer(repeating: 0xFF, count: 10_000_000)
            try await app.testing().test(
                .POST, "/v1.51/libpod/images/import?reference=foo@sha256:\(String(repeating: "a", count: 64))",
                body: hugeGarbageBody
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("cannot reference"))
            }
        }

        #expect(!(await client.importImageWasCalled), "importImage must not run when the reference is a digest")
    }
}
