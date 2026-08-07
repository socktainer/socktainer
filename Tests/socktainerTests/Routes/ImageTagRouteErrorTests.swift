import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("ImageTagRoute — Docker image identity errors")
struct ImageTagRouteErrorTests {
    @Test("a missing source returns Docker's exact 404 message")
    func missingSourceIsNotFound() async throws {
        try await withTagApp(failure: .notFound) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/images/demo:old/tag?repo=demo&tag=new"
            ) { response async throws in
                #expect(response.status == .notFound)
                let body = try response.content.decode(DockerErrorBody.self)
                #expect(body.message == "No such image: demo:old")
            }
        }
    }

    @Test("an ambiguous source returns Docker's exact 409 message")
    func ambiguousSourceIsConflict() async throws {
        try await withTagApp(failure: .ambiguous) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/images/abc123/tag?repo=demo&tag=new"
            ) { response async throws in
                #expect(response.status == .conflict)
                let body = try response.content.decode(DockerErrorBody.self)
                #expect(body.message == "conflict: abc123 is an ambiguous image ID")
            }
        }
    }

    @Test("tag event uses Docker config ID instead of Apple root digest")
    func tagEventUsesConfigDigest() async throws {
        let root = "sha256:" + String(repeating: "1", count: 64)
        let config = "sha256:" + String(repeating: "2", count: 64)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let capture = Task<DockerEvent?, Never> {
            for await event in stream
            where event.Type == "image" && event.Action == "tag" {
                return event
            }
            return nil
        }

        try await withApp { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(
                collection: ImageTagRoute(
                    systemConfig: ContainerSystemConfig(),
                    tagger: SuccessfulImageTagger(
                        rootDigest: root,
                        configDigest: config
                    )
                )
            )
            try await app.testing().test(
                .POST,
                "/v1.51/images/demo:old/tag?repo=demo&tag=new"
            ) { response async in
                #expect(response.status == .created)
            }
        }

        let timeout = Task {
            try? await Task.sleep(for: .seconds(1))
            capture.cancel()
        }
        let event = await capture.value
        timeout.cancel()
        #expect(event?.Actor.ID == config)
        #expect(
            event?.Actor.Attributes["name"]
                == "docker.io/library/demo:new"
        )
    }
}

private enum TagFailure: Sendable {
    case notFound
    case ambiguous
}

private struct ThrowingImageTagger: ImageTaggingProtocol {
    let failure: TagFailure

    func tag(source: String, target: String) async throws -> ImageTaggingResult {
        switch failure {
        case .notFound:
            throw ClientImageError.notFound(id: source)
        case .ambiguous:
            throw ClientImageError.conflict("conflict: \(source) is an ambiguous image ID")
        }
    }
}

private struct SuccessfulImageTagger: ImageTaggingProtocol {
    let rootDigest: String
    let configDigest: String

    func tag(source: String, target: String) async throws -> ImageTaggingResult {
        ImageTaggingResult(
            image: ClientImage(
                description: ImageDescription(
                    reference: target,
                    descriptor: Descriptor(
                        mediaType: MediaTypes.index,
                        digest: rootDigest,
                        size: 1
                    )
                )
            ),
            dockerConfigDigest: configDigest
        )
    }
}

private struct DockerErrorBody: Vapor.Content {
    let message: String
}

private func withTagApp(
    failure: TagFailure,
    run: (Application) async throws -> Void
) async throws {
    try await withApp(configure: { app in
        app.middleware.use(DockerErrorMiddleware(), at: .beginning)
    }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.register(
            collection: ImageTagRoute(
                systemConfig: ContainerSystemConfig(),
                tagger: ThrowingImageTagger(failure: failure)
            ))
        try await run(app)
    }
}
