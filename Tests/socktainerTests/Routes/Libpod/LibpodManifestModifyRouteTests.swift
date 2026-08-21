import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("LibpodManifestModifyRoute")
struct LibpodManifestModifyRouteTests {
    @Test("default operation (no 'operation' param) adds images, matching podman's 'update' default")
    func defaultOperationAdds() async throws {
        let receivedImages = Box<[String]?>(nil)
        let client = MockManifestClient(addHandler: { _, images in
            await receivedImages.set(images)
            return "sha256:added"
        })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?images=alpine:latest") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(RESTManifestIDResponse.self, from: Data(buffer: res.body))
                #expect(body.ID == "sha256:added")
            }
        }
        #expect(await receivedImages.get() == ["alpine:latest"])
    }

    @Test("explicit operation=update adds images the same as the default")
    func explicitUpdateAdds() async throws {
        let addCalled = Box(false)
        let client = MockManifestClient(addHandler: { _, _ in
            await addCalled.set(true)
            return "sha256:added"
        })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=update&images=alpine:latest") { res async throws in
                #expect(res.status == .ok)
            }
        }
        #expect(await addCalled.get())
    }

    @Test("update with no images is a 400, not an empty no-op update")
    func updateWithNoImagesIs400() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("operation=remove removes each listed digest in order")
    func removeDigests() async throws {
        let removedDigests = Box<[String]>([])
        let client = MockManifestClient(
            inspectHandler: { _ in
                Index(manifests: [
                    Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:aaa", size: 100),
                    Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:bbb", size: 100),
                ])
            },
            removeDigestHandler: { _, digest in
                await removedDigests.set(await removedDigests.get() + [digest])
                return "sha256:afterremoval"
            })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=remove&images=sha256:aaa&images=sha256:bbb") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(RESTManifestIDResponse.self, from: Data(buffer: res.body))
                #expect(body.ID == "sha256:afterremoval")
            }
        }
        #expect(await removedDigests.get() == ["sha256:aaa", "sha256:bbb"])
    }

    @Test("remove with no images is a 400")
    func removeWithNoImagesIs400() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=remove") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("a later invalid digest in a multi-digest remove is rejected before any digest is actually removed")
    func removeRejectsBeforeMutatingWhenADigestIsInvalid() async throws {
        let removedDigests = Box<[String]>([])
        let client = MockManifestClient(
            inspectHandler: { _ in
                // Only "sha256:aaa" is an actual member — "sha256:bbb" is not.
                Index(manifests: [Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:aaa", size: 100)])
            },
            removeDigestHandler: { _, digest in
                await removedDigests.set(await removedDigests.get() + [digest])
                return "sha256:afterremoval"
            })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=remove&images=sha256:aaa&images=sha256:bbb") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
        // Neither digest was actually removed — validation ran before any mutation, even
        // though "sha256:aaa" alone would have succeeded if processed first.
        #expect(await removedDigests.get() == [])
    }

    @Test("a digest requested twice in the same remove is rejected before any digest is actually removed")
    func removeRejectsDuplicateDigestBeforeMutating() async throws {
        let removedDigests = Box<[String]>([])
        let client = MockManifestClient(
            inspectHandler: { _ in
                Index(manifests: [Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:aaa", size: 100)])
            },
            removeDigestHandler: { _, digest in
                await removedDigests.set(await removedDigests.get() + [digest])
                return "sha256:afterremoval"
            })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=remove&images=sha256:aaa&images=sha256:aaa") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
        // Without the duplicate check, the first occurrence would succeed and the second
        // would fail (no longer a member after the first removal) — a partial mutation
        // masquerading as a whole-request failure, the exact bug this pre-check prevents.
        #expect(await removedDigests.get() == [])
    }

    @Test("operation=annotate is not implemented")
    func annotateIsNotImplemented() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=annotate") { res async throws in
                #expect(res.status == .notImplemented)
            }
        }
    }

    @Test("an unknown operation is a 400")
    func unknownOperationIs400() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=bogus") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("an image add can't resolve surfaces as 400, not a raw error")
    func addNotFoundImageIs400() async throws {
        let client = MockManifestClient(addHandler: { _, _ in
            throw ClientImageError.notFound(id: "does-not-exist:latest")
        })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?images=does-not-exist:latest") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("removing from a nonexistent manifest list is a 404")
    func removeFromNonexistentManifestIs404() async throws {
        let client = MockManifestClient(
            inspectHandler: { name in throw ClientManifestError.notFound(name: name) },
            removeDigestHandler: { name, _ in
                throw ClientManifestError.notFound(name: name)
            })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/ghost?operation=remove&images=sha256:aaa") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    // MARK: - Helper

    private func withModifyApp(client: MockManifestClient, test: @escaping (Application) async throws -> Void) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodManifestModifyRoute(client: client))
            try await test(app)
        }
    }
}
