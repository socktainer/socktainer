import ContainerResource
import ContainerizationError
import Testing

@testable import GlassDock

/// `VolumeNotFound.matches` is the single source of truth for turning a
/// volume-not-found error into a 404 (or a forced 204). It must recognize the
/// two well-defined shapes a missing volume takes, and — just as importantly —
/// must NOT catch an unrelated backend failure, which would silently downgrade a
/// 500 to a 404 or swallow it under `force`.
@Suite("VolumeNotFound.matches")
struct VolumeNotFoundTests {

    @Test("The framework's typed VolumeError.volumeNotFound matches")
    func typedMatches() {
        #expect(VolumeNotFound.matches(VolumeError.volumeNotFound("ghost")))
    }

    @Test("The XPC-flattened .invalidArgument \"volume '<name>' not found\" matches")
    func flattenedMatches() {
        #expect(VolumeNotFound.matches(ContainerizationError(.invalidArgument, message: "volume 'ghost' not found")))
    }

    @Test("A ContainerizationError with the .notFound code matches")
    func notFoundCodeMatches() {
        #expect(VolumeNotFound.matches(ContainerizationError(.notFound, message: "not found")))
    }

    @Test("Unrelated errors do not match")
    func unrelatedDoesNotMatch() {
        // A different VolumeError case.
        #expect(!VolumeNotFound.matches(VolumeError.storageError("disk gone")))
        // .invalidArgument, but not the volume-not-found envelope.
        #expect(!VolumeNotFound.matches(ContainerizationError(.invalidArgument, message: "some other invalid argument")))
        // The right words, but the wrong code (e.g. an internal failure that
        // merely mentions a volume) must not be downgraded to a 404.
        #expect(!VolumeNotFound.matches(ContainerizationError(.internalError, message: "volume 'x' not found")))
        // A bare Swift error carrying the words must not match either.
        struct Bogus: Error { let msg = "volume 'x' not found" }
        #expect(!VolumeNotFound.matches(Bogus()))
    }
}
