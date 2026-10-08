import Testing

@testable import socktainer

@Suite("ImageIDResolver")
struct ImageIDResolverTests {
    static let hex = "ad4f11f7c85f87c0a6d6c0fe492ad53f9cdcff6e8c88b881360c70eff701c67b"

    @Test("accepts full and short IDs, with or without sha256:")
    func acceptsIDs() {
        #expect(ImageIDResolver.candidateID("sha256:\(Self.hex)") == Self.hex)
        #expect(ImageIDResolver.candidateID(Self.hex) == Self.hex)
        #expect(ImageIDResolver.candidateID("bdf57e528e45") == "bdf57e528e45")
        #expect(ImageIDResolver.candidateID("sha256:bdf57e528e45") == "bdf57e528e45")
    }

    @Test("rejects references and malformed IDs")
    func rejectsNonIDs() {
        #expect(ImageIDResolver.candidateID("busybox:1.37") == nil)
        #expect(ImageIDResolver.candidateID("busybox") == nil)
        #expect(ImageIDResolver.candidateID("bdf57e528e4") == nil)  // 11 chars
        #expect(ImageIDResolver.candidateID("BDF57E528E45") == nil)
        #expect(ImageIDResolver.candidateID("bdf57e528e4z") == nil)
        #expect(ImageIDResolver.candidateID(Self.hex + "0") == nil)
    }

    @Test("matches a digest by full or short prefix")
    func matchesDigest() {
        let digest = "sha256:\(Self.hex)"
        #expect(ImageIDResolver.matches(Self.hex, digest: digest))
        #expect(ImageIDResolver.matches("ad4f11f7c85f", digest: digest))
        #expect(!ImageIDResolver.matches("bdf57e528e45", digest: digest))
    }
}
