import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Testing
import Vapor

@testable import socktainer

@Suite("Image identity route semantics")
struct ImageIdentityRouteSemanticsTests {
    private static func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }

    private static func image(reference: String, digest: String) -> ClientImage {
        ClientImage(
            description: ImageDescription(
                reference: reference,
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: digest,
                    size: 100
                )
            )
        )
    }

    @Test("history uses the platform implied by a manifest or config identity")
    func historyUsesImpliedPlatform() throws {
        let arm64 = Platform(arch: "arm64", os: "linux", variant: nil)

        let selected = try ImageHistoryRoute.selectedPlatform(
            explicit: nil,
            implied: arm64,
            requestedName: Self.digest("a")
        )

        #expect(selected == arm64)
    }

    @Test("history rejects an explicit platform that conflicts with the image identity")
    func historyRejectsConflictingPlatform() throws {
        let arm64 = Platform(arch: "arm64", os: "linux", variant: nil)
        let amd64 = Platform(arch: "amd64", os: "linux", variant: nil)
        let name = Self.digest("b")

        do {
            _ = try ImageHistoryRoute.selectedPlatform(
                explicit: amd64,
                implied: arm64,
                requestedName: name
            )
            Issue.record("Expected a conflicting platform to be rejected")
        } catch let error as Abort {
            #expect(error.status == .notFound)
            #expect(error.reason == "Image '\(name)' does not provide platform 'linux/amd64'")
        }
    }

    @Test("history accepts an explicit platform that matches the image identity")
    func historyAcceptsMatchingPlatform() throws {
        let arm64 = Platform(arch: "arm64", os: "linux", variant: nil)

        let selected = try ImageHistoryRoute.selectedPlatform(
            explicit: arm64,
            implied: arm64,
            requestedName: Self.digest("c")
        )

        #expect(selected == arm64)
    }

    @Test("image list aggregates every stored reference that shares an OCI root")
    func listAggregatesReferencesByRootIdentity() {
        let sharedRoot = Self.digest("1")
        let otherRoot = Self.digest("2")
        let images = [
            Self.image(reference: "docker.io/library/example:second", digest: sharedRoot),
            Self.image(reference: "ghcr.io/acme/example:mirror", digest: sharedRoot),
            Self.image(reference: "docker.io/library/other:latest", digest: otherRoot),
            Self.image(reference: "docker.io/library/example:first", digest: sharedRoot),
        ]

        let groups = ImageListRoute.groupByIdentity(images)

        #expect(groups.count == 2)
        #expect(
            groups[0].references == [
                "docker.io/library/example:first",
                "docker.io/library/example:second",
                "ghcr.io/acme/example:mirror",
            ]
        )
        #expect(groups[0].image.reference == "docker.io/library/example:first")
        #expect(groups[1].references == ["docker.io/library/other:latest"])
    }

    @Test("image list emits one root repo digest per repository across aggregated tags")
    func listAggregatesRepositoryDigests() {
        let root = Self.digest("d")
        let metadata = ImageListRoute.repositoryMetadata(
            references: [
                "docker.io/library/example:second",
                "ghcr.io/acme/example:mirror",
                "docker.io/library/example:first",
                "docker.io/library/example:first",
            ],
            rootDigest: root,
            includeDigests: true
        )

        #expect(
            metadata.tags == [
                "docker.io/library/example:first",
                "docker.io/library/example:second",
                "ghcr.io/acme/example:mirror",
            ]
        )
        #expect(
            metadata.digests == [
                "docker.io/library/example@\(root)",
                "ghcr.io/acme/example@\(root)",
            ]
        )
    }

    @Test("image list omits repo digests unless requested")
    func listHonorsDigestQuery() {
        let metadata = ImageListRoute.repositoryMetadata(
            references: ["docker.io/library/example:latest"],
            rootDigest: Self.digest("e"),
            includeDigests: false
        )

        #expect(metadata.tags == ["docker.io/library/example:latest"])
        #expect(metadata.digests.isEmpty)
    }
}
