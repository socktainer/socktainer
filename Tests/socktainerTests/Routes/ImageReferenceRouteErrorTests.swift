import ContainerAPIClient
import Containerization
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("Image reference routes — Docker identity errors")
struct ImageReferenceRouteErrorTests {
    @Test("pull streams immutable-association conflicts in Docker error framing")
    func pullImmutableAssociationConflictIsDockerFramed() async throws {
        let client = ThrowingImageClient(failure: .streamConflict)
        try await withReferenceErrorApp(client: client) { app in
            try app.register(collection: ImageCreateRoute(client: client))

            try await app.testing().test(
                .POST,
                "/v1.51/images/create?fromImage=registry.example.test%2Fteam%2Fexample&tag=latest"
            ) { response async throws in
                #expect(response.status == .ok)
                let frame = try JSONDecoder().decode(
                    PullErrorFrame.self,
                    from: Data(response.body.readableBytesView)
                )
                #expect(
                    frame.error
                        == "conflict: registry.example.test/team/example has conflicting image assignments"
                )
                #expect(!response.body.string.contains("conflictingAssignments("))
            }
        }
    }

    @Test("push preserves an ambiguous image ID as a 409 conflict")
    func pushAmbiguousImageIsConflict() async throws {
        try await withReferenceErrorApp(client: ThrowingImageClient(failure: .ambiguous)) {
            app in
            try app.register(
                collection: ImagePushRoute(
                    client: ThrowingImageClient(failure: .ambiguous)))

            try await app.testing().test(
                .POST,
                "/v1.51/images/abc123/push"
            ) { response async throws in
                #expect(response.status == .conflict)
                let body = try response.content.decode(ReferenceRouteErrorBody.self)
                #expect(body.message == "conflict: abc123 is an ambiguous image ID")
            }
        }
    }

    @Test("save reports a missing image with Docker's exact 404 message")
    func saveMissingImageIsNotFound() async throws {
        let client = ThrowingImageClient(failure: .notFound)
        try await withReferenceErrorApp(client: client) { app in
            try app.register(collection: ImagesGetRoute(client: client))

            try await app.testing().test(
                .GET,
                "/v1.51/images/ghost:latest/get"
            ) { response async throws in
                #expect(response.status == .notFound)
                let body = try response.content.decode(ReferenceRouteErrorBody.self)
                #expect(body.message == "No such image: ghost:latest")
            }
        }
    }

    @Test("save preserves an ambiguous image ID as a 409 conflict")
    func saveAmbiguousImageIsConflict() async throws {
        let client = ThrowingImageClient(failure: .ambiguous)
        try await withReferenceErrorApp(client: client) { app in
            try app.register(collection: ImagesGetRoute(client: client))

            try await app.testing().test(
                .GET,
                "/v1.51/images/abc123/get"
            ) { response async throws in
                #expect(response.status == .conflict)
                let body = try response.content.decode(ReferenceRouteErrorBody.self)
                #expect(body.message == "conflict: abc123 is an ambiguous image ID")
            }
        }
    }
}

private enum ReferenceRouteFailure: Sendable {
    case notFound
    case ambiguous
    case streamConflict
}

private struct ThrowingImageClient: ClientImageProtocol {
    let failure: ReferenceRouteFailure

    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }

    func delete(id: String) async throws -> ImageDeletionResult {
        throw imageError(id)
    }

    func pull(
        image: String,
        tag: String?,
        platform: Platform,
        fallbackPolicy: PlatformFallbackPolicy,
        logger: Logger
    ) async throws -> AsyncThrowingStream<PullProgress, Error> {
        if case .streamConflict = failure {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: ClientImageError.conflict(
                        "conflict: \(image) has conflicting image assignments"
                    )
                )
            }
        }
        throw imageError(image)
    }

    func push(
        reference: String,
        platform: Platform?,
        logger: Logger
    ) async throws -> AsyncThrowingStream<String, Error> {
        throw imageError(reference)
    }

    func prune(
        filters: [String: [String]],
        logger: Logger
    ) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
        ([], 0)
    }

    func load(
        tarballPath: URL,
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> [String] {
        []
    }

    func save(
        references: [String],
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> URL {
        throw imageError(references.first ?? "")
    }

    func importImage(
        tarPath: URL,
        repo: String?,
        tag: String?,
        message: String?,
        changes: [String],
        platform: Platform,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> (reference: String?, digest: String) {
        throw imageError(repo ?? "")
    }

    private func imageError(_ id: String) -> ClientImageError {
        switch failure {
        case .notFound:
            return .notFound(id: id)
        case .ambiguous:
            return .conflict("conflict: \(id) is an ambiguous image ID")
        case .streamConflict:
            return .conflict(
                "conflict: \(id) has conflicting image assignments"
            )
        }
    }
}

private struct ReferenceRouteErrorBody: Vapor.Content {
    let message: String
}

private struct PullErrorFrame: Decodable {
    let error: String
}

private func withReferenceErrorApp(
    client: ThrowingImageClient,
    run: (Application) async throws -> Void
) async throws {
    try await withApp(configure: { app in
        app.middleware.use(DockerErrorMiddleware(), at: .beginning)
    }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[AppleContainerAppSupportUrlKey.self] =
            FileManager.default.temporaryDirectory
        try await run(app)
    }
}
