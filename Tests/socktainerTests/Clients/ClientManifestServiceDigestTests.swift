import Testing

@testable import socktainer

/// `removeDigest` and `removeDigests` must accept the same digest spellings, so a bare hex
/// digest isn't rejected just because it arrived through the plural (batch) path.
@Suite("ClientManifestService digest normalization")
struct ClientManifestServiceDigestTests {
    private let hex = String(repeating: "a", count: 64)

    @Test("a bare hex digest is assumed sha256")
    func bareHexGetsSha256Prefix() throws {
        #expect(try ClientManifestService.normalizedDigest(hex) == "sha256:\(hex)")
    }

    @Test("a sha256-prefixed digest is returned unchanged")
    func prefixedDigestUnchanged() throws {
        #expect(try ClientManifestService.normalizedDigest("sha256:\(hex)") == "sha256:\(hex)")
    }

    @Test("a digest with a different algorithm prefix is rejected, not re-prefixed")
    func otherAlgorithmRejected() {
        #expect(throws: (any Error).self) {
            try ClientManifestService.normalizedDigest("sha512:\(hex)")
        }
    }
}
