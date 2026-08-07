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

    @Test("non-host repository digest is listed under its exact platform config")
    func repositoryDigestSelectsNonHostConfig() {
        let root = Self.digest("6")
        let hostConfig = Self.digest("7")
        let nonHostConfig = Self.digest("8")
        let nonHostManifest = Self.digest("9")
        let repositoryDigest =
            "docker.io/library/example@\(nonHostManifest)"
        let summary = RESTImageSummary(
            Id: hostConfig,
            ParentId: "",
            RepoTags: [],
            RepoDigests: [repositoryDigest],
            Created: 1,
            Size: 2,
            SharedSize: -1,
            Labels: ["arch": "arm64"],
            Containers: 0,
            Manifests: nil,
            Descriptor: OCIDescriptor(
                mediaType: MediaTypes.index,
                digest: root,
                size: 100,
                urls: nil,
                annotations: nil,
                data: nil,
                platform: nil,
                artifactType: nil
            )
        )

        let rows = ImageListRoute.splitSummary(
            summary,
            rootSelections: [
                .init(
                    reference: repositoryDigest,
                    rootDigest: root,
                    configDigest: nonHostConfig
                )
            ],
            metadataByConfig: [
                nonHostConfig: .init(
                    created: 3,
                    size: 4,
                    labels: ["arch": "amd64"],
                    containers: 1,
                    manifestDigests: [nonHostManifest]
                )
            ]
        )
        let hiddenRows = ImageListRoute.splitSummary(
            summary,
            rootSelections: [
                .init(
                    reference: repositoryDigest,
                    rootDigest: root,
                    configDigest: nonHostConfig
                )
            ],
            metadataByConfig: [
                nonHostConfig: .init(
                    created: 3,
                    size: 4,
                    labels: ["arch": "amd64"],
                    containers: 1,
                    manifestDigests: [nonHostManifest]
                )
            ],
            includeDigests: false
        )

        #expect(rows.count == 1)
        #expect(rows.first?.Id == nonHostConfig)
        #expect(rows.first?.RepoTags.isEmpty == true)
        #expect(rows.first?.RepoDigests == [repositoryDigest])
        #expect(rows.first?.Labels == ["arch": "amd64"])
        #expect(rows.first?.Containers == 1)
        #expect(hiddenRows.count == 1)
        #expect(hiddenRows.first?.Id == nonHostConfig)
        #expect(hiddenRows.first?.RepoDigests.isEmpty == true)
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

    @Test("image list parses Docker CLI reference filter encoding")
    func listParsesReferenceFilters() throws {
        let currentValue = try ImageListRoute.referenceFilter(
            #"{"reference":{"other:*":false,"easylink-postgis:17-3.5":true}}"#
        )
        let legacyValue = try ImageListRoute.referenceFilter(
            #"{"reference":["easylink-postgis:17-3.5"]}"#
        )
        let current = try #require(currentValue)
        let legacy = try #require(legacyValue)

        #expect(
            current.patterns
                == ["easylink-postgis:17-3.5", "other:*"]
        )
        #expect(legacy.patterns == ["easylink-postgis:17-3.5"])
    }

    @Test("malformed reference filter shapes and NUL patterns fail closed")
    func listRejectsMalformedReferenceFilters() {
        for raw in [
            #"{"reference":"example:latest"}"#,
            #"{"reference":{"example:latest":"true"}}"#,
            #"{"reference":[true]}"#,
            #"{"reference":["example:latest"],"dangling":{"true":true}}"#,
            #"{"reference":["example\u0000:latest"]}"#,
            "not-json",
        ] {
            #expect(throws: Abort.self) {
                _ = try ImageListRoute.referenceFilter(raw)
            }
        }
    }

    @Test("exact reference filter returns only the matching root association")
    func listFiltersExactReference() throws {
        let filter = try ImageListRoute.DockerReferenceFilter(
            patterns: ["easylink-postgis:17-3.5"]
        )
        let filtered = ImageListRoute.references(
            [
                "docker.io/library/easylink-postgis:17-3.5",
                "docker.io/library/easylink-postgis:old",
                "docker.io/library/unrelated:latest",
            ],
            matching: filter
        )

        #expect(
            filtered
                == ["docker.io/library/easylink-postgis:17-3.5"]
        )
    }

    @Test("reference filters match familiar, canonical, and glob forms")
    func listFiltersDockerReferenceForms() throws {
        for pattern in [
            "example",
            "example:lat*",
            "docker.io/library/example",
            "docker.io/library/example:latest",
        ] {
            let filter = try ImageListRoute.DockerReferenceFilter(
                patterns: [pattern]
            )
            let filtered = ImageListRoute.references(
                ["docker.io/library/example:latest"],
                matching: filter
            )
            #expect(filtered.count == 1, "pattern \(pattern)")
        }
    }

    @Test("an exact tag filter does not infer ownership of repository digests")
    func listExactTagDoesNotJoinRepositoryDigests() throws {
        let digest = "docker.io/library/example@\(Self.digest("c"))"
        let unrelatedDigest = "ghcr.io/acme/example@\(Self.digest("d"))"
        let filter = try ImageListRoute.DockerReferenceFilter(
            patterns: ["example:latest"]
        )

        let filtered = ImageListRoute.references(
            [
                "docker.io/library/example:latest",
                "docker.io/library/example:old",
                digest,
                unrelatedDigest,
            ],
            matching: filter
        )

        #expect(filtered == ["docker.io/library/example:latest"])
    }

    @Test("reference glob does not cross repository path separators")
    func listReferenceGlobUsesPathSemantics() throws {
        let shallow = try ImageListRoute.DockerReferenceFilter(
            patterns: ["ghcr.io/*"]
        )
        let nested = try ImageListRoute.DockerReferenceFilter(
            patterns: ["ghcr.io/*/*"]
        )

        #expect(
            ImageListRoute.references(
                ["ghcr.io/acme/example:latest"],
                matching: shallow
            ).isEmpty
        )
        #expect(
            ImageListRoute.references(
                ["ghcr.io/acme/example:latest"],
                matching: nested
            ).count == 1
        )
    }

    @Test("same-config roots are filtered before metadata rows merge")
    func listFiltersRootsBeforeConfigMerge() throws {
        let config = Self.digest("e")
        let matchingRoot = Self.digest("f")
        let nonmatchingRoot = Self.digest("0")
        let filter = try ImageListRoute.DockerReferenceFilter(
            patterns: ["wanted:latest"]
        )
        let roots = [
            (
                digest: matchingRoot,
                references: ["docker.io/library/wanted:latest"],
                containers: 1
            ),
            (
                digest: nonmatchingRoot,
                references: ["docker.io/library/other:latest"],
                containers: 9
            ),
        ]

        let rootRows = roots.compactMap { root -> RESTImageSummary? in
            let references = ImageListRoute.references(
                root.references,
                matching: filter
            )
            guard !references.isEmpty else { return nil }
            return RESTImageSummary(
                Id: config,
                ParentId: "",
                RepoTags: references,
                RepoDigests: [],
                Created: 1,
                Size: 2,
                SharedSize: -1,
                Labels: ["root": root.digest],
                Containers: root.containers,
                Manifests: [
                    ImageManifestSummary(
                        ID: root.digest,
                        Descriptor: nil,
                        Available: true,
                        Kind: "image",
                        Size: nil,
                        ImageData: nil,
                        AttestationData: nil
                    )
                ],
                Descriptor: OCIDescriptor(
                    mediaType: MediaTypes.index,
                    digest: root.digest,
                    size: 100,
                    urls: nil,
                    annotations: nil,
                    data: nil,
                    platform: nil,
                    artifactType: nil
                )
            )
        }
        let merged = ImageListRoute.mergeByDockerImageID(rootRows)

        #expect(merged.count == 1)
        #expect(merged.first?.Descriptor?.digest == matchingRoot)
        #expect(merged.first?.Labels["root"] == matchingRoot)
        #expect(merged.first?.Containers == 1)
        #expect(merged.first?.Manifests?.compactMap(\.ID) == [matchingRoot])
        #expect(merged.first?.RepoTags == ["docker.io/library/wanted:latest"])
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
