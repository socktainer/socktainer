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

    // MARK: - repo@sha256:<digest> references

    static let indexHex = String(repeating: "ab", count: 32)

    @Test("parses repo@sha256:<digest> references")
    func parsesDigestReferences() {
        let parsed = ImageIDResolver.parseDigestReference("example/tool@sha256:\(Self.indexHex)")
        #expect(parsed?.repository == "example/tool")
        #expect(parsed?.digest == "sha256:\(Self.indexHex)")
        #expect(ImageIDResolver.parseDigestReference("docker.io/library/busybox@sha256:\(Self.indexHex)")?.repository == "docker.io/library/busybox")
    }

    @Test("rejects plain references, tags and malformed digests")
    func rejectsNonDigestReferences() {
        #expect(ImageIDResolver.parseDigestReference("busybox:1.37") == nil)
        #expect(ImageIDResolver.parseDigestReference("busybox") == nil)
        #expect(ImageIDResolver.parseDigestReference("sha256:\(Self.indexHex)") == nil)
        #expect(ImageIDResolver.parseDigestReference("busybox@sha256:abc") == nil)
        #expect(ImageIDResolver.parseDigestReference("busybox@md5:\(Self.indexHex)") == nil)
        #expect(ImageIDResolver.parseDigestReference("@sha256:\(Self.indexHex)") == nil)
    }

    @Test("repository comparison ignores the docker.io and library/ defaults, tags and digests")
    func repositoryMatching() {
        #expect(ImageIDResolver.repositoryMatches("busybox", "docker.io/library/busybox:1.37"))
        #expect(ImageIDResolver.repositoryMatches("library/busybox", "busybox"))
        #expect(ImageIDResolver.repositoryMatches("example/tool", "docker.io/example/tool:arm64-v1"))
        #expect(ImageIDResolver.repositoryMatches("ghcr.io/apple/container", "ghcr.io/apple/container:latest"))
        #expect(ImageIDResolver.repositoryMatches("localhost:5000/app", "localhost:5000/app:dev"))
        #expect(!ImageIDResolver.repositoryMatches("busybox", "docker.io/library/alpine:3"))
        #expect(!ImageIDResolver.repositoryMatches("ghcr.io/apple/container", "docker.io/apple/container:latest"))
    }

    static let manifestHex = String(repeating: "12", count: 32)
    @Test("a digest equal to the index digest matches the index")
    func digestMatchesIndex() {
        let match = ImageIDResolver.digestMatch(
            "sha256:\(Self.indexHex)", indexDigest: "sha256:\(Self.indexHex)",
            manifests: [(digest: "sha256:\(Self.manifestHex)", platform: Self.arm64)])
        #expect(match == .index)
    }

    @Test("a per-platform manifest digest matches and carries that platform")
    func digestMatchesManifest() {
        // RepoDigests reports the selected platform's manifest digest, which is what clients send back.
        let match = ImageIDResolver.digestMatch(
            "sha256:\(Self.manifestHex)", indexDigest: "sha256:\(Self.indexHex)",
            manifests: [
                (digest: "sha256:" + String(repeating: "34", count: 32), platform: Self.amd64),
                (digest: "sha256:\(Self.manifestHex)", platform: Self.arm64),
            ])
        #expect(match == .manifest(Self.arm64))
    }

    @Test("an unknown digest matches nothing")
    func digestMatchesNothing() {
        let other = "sha256:" + String(repeating: "ef", count: 32)
        let match = ImageIDResolver.digestMatch(
            other, indexDigest: "sha256:\(Self.indexHex)",
            manifests: [(digest: "sha256:\(Self.manifestHex)", platform: Self.arm64)])
        #expect(match == nil)
    }

    @Test("a repository qualified with a private default registry only matches that registry")
    func repositoryWithPrivateDefaultRegistry() {
        // resolve() qualifies the requested repository with the configured default registry
        // before comparing, so an image that shares the digest under Docker Hub is not picked.
        #expect(ImageIDResolver.repositoryMatches("registry.example.com/team/app", "registry.example.com/team/app:latest"))
        #expect(!ImageIDResolver.repositoryMatches("registry.example.com/team/app", "docker.io/team/app:latest"))
        #expect(!ImageIDResolver.repositoryMatches("docker.io/team/app", "registry.example.com/team/app:latest"))
        #expect(ImageIDResolver.repositoryMatches("docker.io/team/app", "team/app:latest"))
    }
}
