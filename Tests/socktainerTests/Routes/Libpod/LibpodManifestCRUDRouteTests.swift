import ContainerizationError
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Route-level coverage for the manifest CRUD endpoints (`create`/`inspect`/`exists`/`delete`)
/// via a mocked `ClientManifestServiceProtocol` — no real `ImageStore`/XPC dependency, unlike
/// `ClientManifestService`'s own tests (see `ClientManifestServiceRetagTests`, which documents
/// why its underlying logic can't be mocked this way). This exercises the HTTP layer: query/body
/// param decoding, status codes, response shape.
@Suite("LibpodManifestCreateRoute")
struct LibpodManifestCreateRouteTests {
    @Test("images via the 'image' query param are forwarded to create, response carries the digest")
    func imageQueryParam() async throws {
        let receivedName = Box<String?>(nil)
        let receivedImages = Box<[String]?>(nil)
        let client = MockManifestClient(createHandler: { name, images, _ in
            await receivedName.set(name)
            await receivedImages.set(images)
            return "sha256:aaaa"
        })

        try await withManifestApp(client: client) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/manifests/mylist?image=alpine:latest") { res async throws in
                #expect(res.status == .created)
                let body = try JSONDecoder().decode(RESTManifestIDResponse.self, from: Data(buffer: res.body))
                #expect(body.ID == "sha256:aaaa")
            }
        }
        #expect(await receivedName.get() == "mylist")
        #expect(await receivedImages.get() == ["alpine:latest"])
    }

    @Test("images via a JSON request body are forwarded to create")
    func imagesRequestBody() async throws {
        let receivedImages = Box<[String]?>(nil)
        let client = MockManifestClient(createHandler: { _, images, _ in
            await receivedImages.set(images)
            return "sha256:bbbb"
        })

        try await withManifestApp(client: client) { app in
            try await app.testing().test(
                .POST, "/v1.51/libpod/manifests/mylist",
                beforeRequest: { req in
                    try req.content.encode(RESTManifestCreateRequest(images: ["alpine:latest", "busybox:latest"]))
                }
            ) { res async throws in
                #expect(res.status == .created)
            }
        }
        #expect(await receivedImages.get() == ["alpine:latest", "busybox:latest"])
    }

    @Test("images via a JSON request body WITHOUT a Content-Type header are still forwarded")
    func imagesRequestBodyWithoutContentType() async throws {
        let receivedImages = Box<[String]?>(nil)
        let client = MockManifestClient(createHandler: { _, images, _ in
            await receivedImages.set(images)
            return "sha256:bbbb"
        })

        try await withManifestApp(client: client) { app in
            let body = ByteBuffer(string: #"{"images":["alpine:latest","busybox:latest"]}"#)
            try await app.testing().test(.POST, "/v1.51/libpod/manifests/mylist", body: body) { res async throws in
                #expect(res.status == .created)
            }
        }
        #expect(await receivedImages.get() == ["alpine:latest", "busybox:latest"])
    }

    @Test("a source image ClientImage.get can't find surfaces as 400, not a raw error")
    func notFoundSourceImageIs400() async throws {
        let client = MockManifestClient(createHandler: { _, _, _ in
            throw ClientImageError.notFound(id: "does-not-exist:latest")
        })

        try await withManifestApp(client: client) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/manifests/mylist?image=does-not-exist:latest") { res async throws in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("does-not-exist:latest"))
            }
        }
    }

    @Test("a duplicate manifest list name without ?amend is a 409, matching real podman's default (no --amend) behavior")
    func duplicateNameWithoutAmendIs409() async throws {
        let client = MockManifestClient(createHandler: { name, _, amend in
            #expect(!amend)
            throw ClientManifestError.alreadyExists(name: name)
        })

        try await withManifestApp(client: client) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/manifests/mylist?image=alpine:latest") { res async throws in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("?amend=true is forwarded through to create")
    func amendQueryParamForwarded() async throws {
        let receivedAmend = Box<Bool?>(nil)
        let client = MockManifestClient(createHandler: { _, _, amend in
            await receivedAmend.set(amend)
            return "sha256:aaaa"
        })

        try await withManifestApp(client: client) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/manifests/mylist?image=alpine:latest&amend=true") { res async throws in
                #expect(res.status == .created)
            }
        }
        #expect(await receivedAmend.get() == true)
    }

    @Test("a ContainerizationError.invalidArgument from create surfaces as 400, not a raw 500")
    func invalidArgumentFromCreateIs400() async throws {
        let client = MockManifestClient(createHandler: { name, _, _ in
            throw ContainerizationError(.invalidArgument, message: "\(name) exists but is not a manifest list")
        })

        try await withManifestApp(client: client) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/manifests/mylist?image=alpine:latest&amend=true") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }
}

@Suite("LibpodManifestInspectRoute")
struct LibpodManifestInspectRouteTests {
    @Test("an existing manifest list returns its index as JSON")
    func existingManifestReturnsIndex() async throws {
        let descriptor = Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:cccc", size: 100)
        let client = MockManifestClient(inspectHandler: { _ in Index(manifests: [descriptor]) })

        try await withManifestApp(client: client) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/manifests/mylist/json") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.description.contains("application/json") == true)
                let index = try JSONDecoder().decode(Index.self, from: Data(buffer: res.body))
                #expect(index.manifests.map(\.digest) == ["sha256:cccc"])
            }
        }
    }

    @Test("a nonexistent manifest list returns 404")
    func nonexistentManifestReturns404() async throws {
        let client = MockManifestClient(inspectHandler: { name in
            throw ClientManifestError.notFound(name: name)
        })

        try await withManifestApp(client: client) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/manifests/ghost/json") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }
}

@Suite("LibpodManifestExistsRoute")
struct LibpodManifestExistsRouteTests {
    @Test("an existing manifest list returns 204 No Content")
    func existingManifestReturns204() async throws {
        let client = MockManifestClient(existsHandler: { _ in true })

        try await withManifestApp(client: client) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/manifests/mylist/exists") { res async throws in
                #expect(res.status == .noContent)
            }
        }
    }

    @Test("a nonexistent manifest list returns 404")
    func nonexistentManifestReturns404() async throws {
        let client = MockManifestClient(existsHandler: { _ in false })

        try await withManifestApp(client: client) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/manifests/ghost/exists") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }
}

@Suite("LibpodManifestDeleteRoute")
struct LibpodManifestDeleteRouteTests {
    @Test("an existing manifest list is deleted and its name echoed back")
    func existingManifestIsDeleted() async throws {
        let deletedName = Box<String?>(nil)
        let client = MockManifestClient(
            existsHandler: { _ in true },
            deleteHandler: { name in await deletedName.set(name) }
        )

        try await withManifestApp(client: client) { app in
            try await app.testing().test(.DELETE, "/v1.51/libpod/manifests/mylist") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(RESTManifestRemoveReport.self, from: Data(buffer: res.body))
                #expect(body.Deleted == ["mylist"])
                #expect(body.ExitCode == 0)
            }
        }
        #expect(await deletedName.get() == "mylist")
    }

    @Test("a nonexistent manifest list without ?ignore returns 404")
    func nonexistentWithoutIgnoreReturns404() async throws {
        let client = MockManifestClient(existsHandler: { _ in false })

        try await withManifestApp(client: client) { app in
            try await app.testing().test(.DELETE, "/v1.51/libpod/manifests/ghost") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("a nonexistent manifest list with ?ignore=true returns 200 without calling delete")
    func nonexistentWithIgnoreReturns200() async throws {
        let deleteCalled = Box(false)
        let client = MockManifestClient(
            existsHandler: { _ in false },
            deleteHandler: { _ in await deleteCalled.set(true) }
        )

        try await withManifestApp(client: client) { app in
            try await app.testing().test(.DELETE, "/v1.51/libpod/manifests/ghost?ignore=true") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(RESTManifestRemoveReport.self, from: Data(buffer: res.body))
                #expect(body.Deleted == [])
                #expect(body.ExitCode == 0)
            }
        }
        #expect(await !deleteCalled.get())
    }
}

// MARK: - Helpers

func withManifestApp(client: MockManifestClient, test: @escaping (Application) async throws -> Void) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.register(collection: LibpodManifestCreateRoute(client: client))
        try app.register(collection: LibpodManifestInspectRoute(client: client))
        try app.register(collection: LibpodManifestExistsRoute(client: client))
        try app.register(collection: LibpodManifestDeleteRoute(client: client))
        try await test(app)
    }
}
