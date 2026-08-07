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

    @Test("same-root constrained tags are reported under their selected config IDs")
    func constrainedTagsSplitInventoryRows() {
        let root = Self.digest("1")
        let armConfig = Self.digest("2")
        let amdConfig = Self.digest("3")
        let summary = RESTImageSummary(
            Id: armConfig,
            ParentId: "",
            RepoTags: [
                "docker.io/library/example:arm64",
                "docker.io/library/example:amd64",
            ],
            RepoDigests: [],
            Created: 1,
            Size: 2,
            SharedSize: -1,
            Labels: [:],
            Containers: 0,
            Manifests: nil,
            Descriptor: nil
        )

        let rows = ImageListRoute.splitSummary(
            summary,
            rootSelections: [
                .init(
                    reference: "docker.io/library/example:arm64",
                    rootDigest: root,
                    configDigest: armConfig
                ),
                .init(
                    reference: "docker.io/library/example:amd64",
                    rootDigest: root,
                    configDigest: amdConfig
                ),
            ],
            metadataByConfig: [
                armConfig: .init(
                    created: 10,
                    size: 20,
                    labels: ["arch": "arm64"],
                    containers: 1,
                    manifestDigests: [Self.digest("4")]
                ),
                amdConfig: .init(
                    created: 30,
                    size: 40,
                    labels: ["arch": "amd64"],
                    containers: 0,
                    manifestDigests: [Self.digest("5")]
                ),
            ]
        )

        #expect(rows.count == 2)
        #expect(
            Dictionary(uniqueKeysWithValues: rows.map { ($0.Id, $0.RepoTags) })
                == [
                    armConfig: ["docker.io/library/example:arm64"],
                    amdConfig: ["docker.io/library/example:amd64"],
                ]
        )
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.Id, $0) })
        #expect(rowsByID[armConfig]?.Created == 10)
        #expect(rowsByID[armConfig]?.Size == 20)
        #expect(rowsByID[armConfig]?.Labels == ["arch": "arm64"])
        #expect(rowsByID[armConfig]?.Containers == 1)
        #expect(rowsByID[amdConfig]?.Created == 30)
        #expect(rowsByID[amdConfig]?.Size == 40)
        #expect(rowsByID[amdConfig]?.Labels == ["arch": "amd64"])
        #expect(rowsByID[amdConfig]?.Containers == 0)
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

    @Test("an anonymous lease-only row attributes its stopped container without exposing a tag")
    func listAttributesLeaseOnlyContainer() {
        let root = Self.digest("8")
        let descriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: root,
            size: 100
        )
        let anonymous = Self.image(reference: root, digest: root)
        let container = ContainerSnapshot(
            configuration: ContainerConfiguration(
                id: "lease-only-container",
                image: ImageDescription(
                    reference: ContainerImageLease.reference(for: root),
                    descriptor: descriptor
                ),
                process: ProcessConfiguration(
                    executable: "/bin/true",
                    arguments: [],
                    environment: [],
                    workingDirectory: "/",
                    terminal: false,
                    user: .id(uid: 0, gid: 0)
                )
            ),
            status: .stopped,
            networks: []
        )
        let group = ImageListRoute.groupByIdentity([anonymous])
        let metadata = ImageListRoute.repositoryMetadata(
            references: group[0].references,
            rootDigest: root,
            includeDigests: true
        )

        #expect(group.count == 1)
        #expect(metadata.tags.isEmpty)
        #expect(metadata.digests.isEmpty)
        #expect(
            ImageListRoute.containerCount(
                usingRootDigest: root,
                in: [container]
            ) == 1
        )
    }

    @Test("local tags do not synthesize unproven repository digests")
    func listDoesNotSynthesizeRepositoryDigests() {
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
        #expect(metadata.digests.isEmpty)
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

    @Test("image list never exposes internal or bare digest references as tags")
    func listHidesInternalReferences() {
        let root = Self.digest("f")
        let metadata = ImageListRoute.repositoryMetadata(
            references: [
                "docker.io/library/example:latest",
                "moby-dangling@\(root)",
                "untagged@\(root)",
                "<none>:<none>",
                root,
            ],
            rootDigest: root,
            includeDigests: true
        )

        #expect(metadata.tags == ["docker.io/library/example:latest"])
        #expect(metadata.digests.isEmpty)
    }

    @Test("digest-only stored references remain exact repository digests")
    func listPreservesDigestOnlyReferences() {
        let root = Self.digest("1")
        let storedDigest = Self.digest("2")
        let exactReference =
            "docker.io/library/example@\(storedDigest)"
        let metadata = ImageListRoute.repositoryMetadata(
            references: [
                exactReference,
                "moby-dangling@\(root)",
                "untagged@\(root)",
                root,
            ],
            rootDigest: root,
            includeDigests: true,
            validRepositoryDigests: [root, storedDigest]
        )

        #expect(metadata.tags.isEmpty)
        #expect(metadata.digests == [exactReference])
    }

    @Test("stored repo digests remain real associations beside local tags")
    func listKeepsOnlyStoredRepositoryDigests() {
        let root = Self.digest("3")
        let storedDigest = Self.digest("4")
        let exactReference = "ghcr.io/acme/example@\(storedDigest)"
        let metadata = ImageListRoute.repositoryMetadata(
            references: [
                "docker.io/library/example:latest",
                exactReference,
            ],
            rootDigest: root,
            includeDigests: true,
            validRepositoryDigests: [root, storedDigest]
        )

        #expect(metadata.digests == [exactReference])
    }

    @Test("stored repo digests outside the image identity graph are hidden")
    func listRejectsUnrelatedStoredRepositoryDigest() {
        let root = Self.digest("5")
        let manifest = Self.digest("6")
        let unrelated = Self.digest("7")
        let metadata = ImageListRoute.repositoryMetadata(
            references: [
                "docker.io/library/example@\(manifest)",
                "docker.io/library/example@\(unrelated)",
                "moby-dangling@\(root)",
                "untagged@\(root)",
                unrelated,
            ],
            rootDigest: root,
            includeDigests: true,
            validRepositoryDigests: [root, manifest]
        )

        #expect(metadata.tags.isEmpty)
        #expect(
            metadata.digests == [
                "docker.io/library/example@\(manifest)"
            ]
        )
    }
}
