import ContainerizationOCI
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

    static let arm64 = Platform(arch: "arm64", os: "linux", variant: nil)
    static let amd64 = Platform(arch: "amd64", os: "linux", variant: nil)
    static let image = ImageIDResolver.Candidate(
        digest: "sha256:aaaa1111" + String(repeating: "0", count: 56),
        configs: [(arm64, "sha256:bbbb1111" + String(repeating: "0", count: 56)), (amd64, "sha256:cccc1111" + String(repeating: "0", count: 56))]
    )

    @Test("an index digest match carries no platform")
    func indexDigestMatch() {
        #expect(ImageIDResolver.uniqueMatch("aaaa1111000000", in: [Self.image]) == .init(digest: Self.image.digest, platform: nil))
    }

    @Test("a config digest match carries that platform")
    func configDigestMatch() {
        #expect(ImageIDResolver.uniqueMatch("cccc1111000000", in: [Self.image]) == .init(digest: Self.image.digest, platform: Self.amd64))
    }

    @Test("the same image listed under several tags is not ambiguous")
    func duplicateTagsNotAmbiguous() {
        #expect(ImageIDResolver.uniqueMatch("bbbb1111000000", in: [Self.image, Self.image])?.platform == Self.arm64)
    }

    @Test("a prefix shared by distinct images is rejected")
    func ambiguousPrefixRejected() {
        let other = ImageIDResolver.Candidate(digest: "sha256:aaaa1111" + String(repeating: "f", count: 56), configs: [])
        #expect(ImageIDResolver.uniqueMatch("aaaa1111", in: [Self.image, other]) == nil)
        #expect(ImageIDResolver.uniqueMatch("aaaa11110000", in: [Self.image, other])?.digest == Self.image.digest)
        #expect(ImageIDResolver.uniqueMatch("aaaa1111ffff", in: [Self.image, other])?.digest == other.digest)
    }

    @Test("no match returns nil")
    func noMatch() {
        #expect(ImageIDResolver.uniqueMatch("dddd11110000", in: [Self.image]) == nil)
    }
}
