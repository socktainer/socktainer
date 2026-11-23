import ContainerizationError
import ContainerizationOCI
import Testing

@testable import socktainer

@Suite("RosettaFallback")
struct RosettaFallbackTests {
    static let arm64 = Platform(arch: "arm64", os: "linux", variant: nil)
    static let amd64 = Platform(arch: "amd64", os: "linux", variant: nil)

    @Test("retries when a pull finds no arm64 manifest")
    func pullWithoutArm64Manifest() {
        let error = ContainerizationError(.unsupported, message: "image sha256:abc does not support required platforms")
        #expect(RosettaFallback.shouldRetryAsAmd64(error, requested: Self.arm64))
    }

    // Apple Container 1.7.1: fetching an image already stored as amd64 (e.g. mcr.microsoft.com/mssql/server)
    // fails in config(for: arm64) with this error rather than the pull's message.
    @Test("retries when a stored image has no arm64 manifest")
    func storedImageWithoutArm64Manifest() {
        let error = ContainerizationError(.unsupported, message: "platform linux/arm64")
        #expect(RosettaFallback.shouldRetryAsAmd64(error, requested: Self.arm64))
    }

    @Test("does not retry when amd64 was requested")
    func amd64Requested() {
        let error = ContainerizationError(.unsupported, message: "platform linux/amd64")
        #expect(!RosettaFallback.shouldRetryAsAmd64(error, requested: Self.amd64))
    }

    @Test("does not retry for unrelated errors")
    func unrelatedErrors() {
        #expect(!RosettaFallback.shouldRetryAsAmd64(ContainerizationError(.notFound, message: "image not found"), requested: Self.arm64))
        #expect(!RosettaFallback.shouldRetryAsAmd64(ContainerizationError(.unsupported, message: "unsupported media type"), requested: Self.arm64))
        #expect(!RosettaFallback.shouldRetryAsAmd64(ContainerizationError(.internalError, message: "digest mismatch"), requested: Self.arm64))
    }

    @Test("amd64 keeps the requested OS and drops the variant")
    func amd64Platform() {
        let platform = RosettaFallback.amd64(like: Platform(arch: "arm64", os: "linux", variant: "v8"))
        #expect(platform.architecture == "amd64")
        #expect(platform.os == "linux")
        #expect(platform.variant == nil)
    }
}
