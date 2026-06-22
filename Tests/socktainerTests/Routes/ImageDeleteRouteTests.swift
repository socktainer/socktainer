import ContainerAPIClient
import ContainerPersistence
import Foundation
import Testing

@testable import socktainer

/// Tests for the image-delete normalization fix (issue IMG-002).
///
/// **Bug**: `ClientImageService.delete(id:)` passed the raw user-supplied reference
/// (e.g. `"myimg:latest"`) directly to Apple Container's delete API. The store indexes
/// images under their fully-qualified form (`"docker.io/library/myimg:latest"`), so the
/// exact-key lookup silently missed — delete returned success but the image was untouched.
///
/// **Fix**: capture the image from `get()` and call `delete(reference: image.reference)`
/// using the normalized key the store actually holds.
@Suite("ClientImageService — delete reference normalization")
struct ImageDeleteRouteTests {

    // MARK: - Fake image store

    /// In-memory stand-in for Apple Container's image persistence layer.
    /// Keys are stored in normalized form (as the real store does). `refsForDigest`
    /// returns only refs that are still alive, matching the post-delete semantics the
    /// production code relies on to determine whether layers were freed.
    final class FakeImageStore: ImageDeletionStore, @unchecked Sendable {
        /// The reference that `normalizedReference(for:)` will return.
        /// Simulates Apple Container normalizing "test:latest" → "docker.io/library/test:latest".
        let storedNormalized: String
        let digest: String

        /// Tracks the exact reference passed to each `delete(reference:)` call.
        private(set) var deleteCalls: [String] = []
        private(set) var cleanUpCallCount = 0
        var cleanUpShouldThrow = false
        private var alive: Set<String>

        init(storedNormalized: String, digest: String = "sha256:abc123", otherRefs: [String] = []) {
            self.storedNormalized = storedNormalized
            self.digest = digest
            self.alive = Set([storedNormalized] + otherRefs)
        }

        func normalizedReference(for id: String, config: ContainerSystemConfig) async throws -> (String, String) {
            (storedNormalized, digest)
        }

        func refsForDigest(_ digest: String) async throws -> [String] {
            // Return alive refs that match the requested digest.
            guard digest == self.digest else { return [] }
            return Array(alive)
        }

        func delete(reference: String) async throws {
            deleteCalls.append(reference)
            alive.remove(reference)
        }

        func cleanUpOrphanedBlobs() async throws -> UInt64 {
            cleanUpCallCount += 1
            if cleanUpShouldThrow { throw NSError(domain: "GCFailed", code: 1) }
            return 0
        }

        var isEmpty: Bool { alive.isEmpty }

        deinit {}
    }

    // MARK: - Bug regression: the store demonstrates WHY using raw id was wrong

    @Test("store property: deleting a raw tag misses the normalized key (root cause of the bug)")
    func storeRejectsRawTagDelete() async throws {
        let store = FakeImageStore(storedNormalized: "docker.io/library/test:latest")

        // The old code called store.delete(reference: "test:latest") directly.
        // Because the store holds the normalized key, this silently misses.
        try await store.delete(reference: "test:latest")

        #expect(
            !store.isEmpty,
            "raw tag delete must not remove the normalized entry — this demonstrates the pre-fix bug"
        )
        #expect(store.deleteCalls == ["test:latest"])
    }

    // MARK: - Fix: delete is called with the normalized reference

    @Test("fixed: ClientImageService.delete() uses the normalized reference from get()")
    func fixedDeleteUsesNormalizedReference() async throws {
        let store = FakeImageStore(storedNormalized: "docker.io/library/test:latest")
        let rawId = "test:latest"

        try await ClientImageService.delete(
            id: rawId,
            containerSystemConfig: ContainerSystemConfig(),
            imageStore: store
        )

        // The normalized reference must have been used for the delete call.
        #expect(
            store.deleteCalls == ["docker.io/library/test:latest"],
            "delete must be called with normalized reference, got: \(store.deleteCalls)")

        // The image is actually gone from the store.
        #expect(store.isEmpty, "image must be deleted from the store after using normalized reference")
    }

    @Test("delete with already-normalized reference works without double-normalization")
    func deleteWithFullyQualifiedRefWorks() async throws {
        let normalized = "docker.io/library/alpine:latest"
        let store = FakeImageStore(storedNormalized: normalized)

        try await ClientImageService.delete(
            id: normalized,
            containerSystemConfig: ContainerSystemConfig(),
            imageStore: store
        )

        #expect(store.deleteCalls == [normalized])
        #expect(store.isEmpty)
    }

    @Test("result is Untagged only when other refs share the same digest")
    func untaggedOnlyWhenOtherRefsExist() async throws {
        // "test:v1" and "test:latest" share the same digest — removing v1 should
        // NOT emit a Deleted entry because the image layers are still referenced.
        let store = FakeImageStore(
            storedNormalized: "docker.io/library/test:v1",
            digest: "sha256:abc123",
            otherRefs: ["docker.io/library/test:latest"]
        )

        let result = try await ClientImageService.delete(
            id: "test:v1",
            containerSystemConfig: ContainerSystemConfig(),
            imageStore: store
        )

        #expect(result.untagged == "docker.io/library/test:v1")
        #expect(result.deletedDigest == nil, "must not include Deleted when other refs still exist")
    }

    @Test("result includes Deleted digest when last reference is removed")
    func deletedDigestIncludedForLastRef() async throws {
        // "test:latest" is the only tag for this digest — removing it should emit Deleted.
        let store = FakeImageStore(
            storedNormalized: "docker.io/library/test:latest",
            digest: "sha256:abc123",
            otherRefs: []
        )

        let result = try await ClientImageService.delete(
            id: "test:latest",
            containerSystemConfig: ContainerSystemConfig(),
            imageStore: store
        )

        #expect(result.untagged == "docker.io/library/test:latest")
        #expect(result.deletedDigest == "sha256:abc123", "must include Deleted digest when last ref removed")
        #expect(store.isEmpty, "image must be gone from store")
    }

    @Test("cleanUpOrphanedBlobs is called after every successful delete")
    func cleanUpCalledAfterDelete() async throws {
        let store = FakeImageStore(storedNormalized: "docker.io/library/test:latest")

        _ = try await ClientImageService.delete(
            id: "test:latest",
            containerSystemConfig: ContainerSystemConfig(),
            imageStore: store
        )

        #expect(store.cleanUpCallCount == 1, "GC must run after delete to free orphaned blobs")
    }

    @Test("GC failure does not fail the delete — tag is already removed")
    func gcFailureDoesNotFailDelete() async throws {
        let store = FakeImageStore(storedNormalized: "docker.io/library/test:latest")
        store.cleanUpShouldThrow = true

        // Delete must succeed even if GC throws — the tag is gone, returning an error
        // here would cause the client to retry a completed operation.
        let result = try await ClientImageService.delete(
            id: "test:latest",
            containerSystemConfig: ContainerSystemConfig(),
            imageStore: store
        )

        #expect(result.untagged == "docker.io/library/test:latest")
        #expect(store.isEmpty, "image must be deleted even when GC fails")
    }

    @Test("delete throws notFound when image does not exist in store")
    func deleteThrowsNotFoundForUnknownImage() async throws {
        struct ThrowingStore: ImageDeletionStore {
            func normalizedReference(for id: String, config: ContainerSystemConfig) async throws -> (String, String) {
                throw NSError(domain: "ContainerNotFound", code: 1)
            }
            func refsForDigest(_ digest: String) async throws -> [String] { [] }
            func delete(reference: String) async throws {}
            func cleanUpOrphanedBlobs() async throws -> UInt64 { 0 }
        }

        await #expect(throws: ClientImageError.self) {
            try await ClientImageService.delete(
                id: "nonexistent:latest",
                containerSystemConfig: ContainerSystemConfig(),
                imageStore: ThrowingStore()
            )
        }
    }
}
