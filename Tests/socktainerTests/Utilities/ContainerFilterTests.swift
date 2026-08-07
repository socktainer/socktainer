import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Testing

@testable import socktainer

@Suite("ClientContainerService.applyFilters")
struct ContainerFilterTests {

    // MARK: - status

    @Test("status=running keeps only running containers")
    func statusRunning() throws {
        let containers = [
            try makeSnapshot(id: "a", status: .running),
            try makeSnapshot(id: "b", status: .stopped),
        ]
        let result = ClientContainerService.applyFilters(containers, filters: ["status": ["running"]])
        #expect(result.map(\.id) == ["a"])
    }

    @Test("status=exited keeps only stopped containers")
    func statusExited() throws {
        let containers = [
            try makeSnapshot(id: "a", status: .running),
            try makeSnapshot(id: "b", status: .stopped),
        ]
        let result = ClientContainerService.applyFilters(containers, filters: ["status": ["exited"]])
        #expect(result.map(\.id) == ["b"])
    }

    // MARK: - label

    @Test("label=key keeps containers that have the key")
    func labelKeyPresence() throws {
        let containers = [
            try makeSnapshot(id: "a", labels: ["env": "prod"]),
            try makeSnapshot(id: "b", labels: ["tier": "web"]),
        ]
        let result = ClientContainerService.applyFilters(containers, filters: ["label": ["env"]])
        #expect(result.map(\.id) == ["a"])
    }

    @Test("label=key=value keeps containers where key equals value")
    func labelKeyValue() throws {
        let containers = [
            try makeSnapshot(id: "a", labels: ["env": "prod"]),
            try makeSnapshot(id: "b", labels: ["env": "dev"]),
            try makeSnapshot(id: "c", labels: [:]),
        ]
        let result = ClientContainerService.applyFilters(containers, filters: ["label": ["env=prod"]])
        #expect(result.map(\.id) == ["a"])
    }

    @Test("multiple label values in one filter key are ANDed")
    func labelMultipleValues() throws {
        let containers = [
            try makeSnapshot(id: "a", labels: ["env": "prod", "tier": "web"]),
            try makeSnapshot(id: "b", labels: ["env": "prod"]),
            try makeSnapshot(id: "c", labels: ["tier": "web"]),
        ]
        let result = ClientContainerService.applyFilters(
            containers, filters: ["label": ["env=prod", "tier=web"]])
        #expect(result.map(\.id) == ["a"])
    }

    // MARK: - id

    @Test("id filter matches exact container id")
    func idExact() throws {
        let containers = [try makeSnapshot(id: "abc"), try makeSnapshot(id: "def")]
        let result = ClientContainerService.applyFilters(containers, filters: ["id": ["abc"]])
        #expect(result.map(\.id) == ["abc"])
    }

    // MARK: - ancestor

    @Test("ancestor filter keeps containers with matching image reference")
    func ancestor() throws {
        let containers = [
            try makeSnapshot(id: "a", image: "alpine:latest"),
            try makeSnapshot(id: "b", image: "nginx:latest"),
        ]
        let result = ClientContainerService.applyFilters(
            containers, filters: ["ancestor": ["alpine:latest"]])
        #expect(result.map(\.id) == ["a"])
    }

    @Test("ancestor resolves to the immutable image root")
    func ancestorIdentityResolution() async throws {
        let digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let resolver = StubImageReferenceResolver(
            identitiesByIdentifier: [
                digest: .init(
                    rootDigests: [digest],
                    references: ["docker.io/library/alpine:3.22", "docker.io/library/alpine:latest"]
                )
            ])
        let resolved = await ClientContainerService.resolveAncestorFilter([digest], with: resolver)
        let containers = [
            try makeSnapshot(id: "a", image: "docker.io/library/alpine:latest", imageDigest: digest),
            try makeSnapshot(id: "b", image: "docker.io/library/nginx:latest", imageDigest: "sha256:bbbb"),
        ]

        let result = ClientContainerService.applyFilters(
            containers,
            filters: ["ancestor": [digest]],
            resolvedAncestors: resolved
        )

        #expect(result.map(\.id) == ["a"])
    }

    @Test("unresolvable ancestor preserves the original filter value")
    func ancestorResolutionFailureOnlyMatchesDigestlessLegacySnapshots() async throws {
        let resolved = await ClientContainerService.resolveAncestorFilter(
            ["legacy:latest"],
            with: StubImageReferenceResolver(identitiesByIdentifier: [:])
        )
        #expect(resolved?.unresolvedReferences == ["legacy:latest"])
        let modern = try makeSnapshot(
            id: "modern",
            image: "legacy:latest",
            imageDigest: "sha256:" + String(repeating: "9", count: 64)
        )
        let legacy = try makeSnapshot(
            id: "legacy",
            image: "legacy:latest",
            imageDigest: ""
        )

        let result = ClientContainerService.applyFilters(
            [modern, legacy],
            filters: ["ancestor": ["legacy:latest"]],
            resolvedAncestors: resolved
        )

        #expect(result.map(\.id) == ["legacy"])
    }

    @Test("ancestor tag replacement matches only containers created from the new root")
    func ancestorAfterTagReplacement() async throws {
        let oldDigest = "sha256:" + String(repeating: "1", count: 64)
        let newDigest = "sha256:" + String(repeating: "2", count: 64)
        let tag = "docker.io/library/example:latest"
        let resolver = StubImageReferenceResolver(
            identitiesByIdentifier: [
                tag: .init(rootDigests: [newDigest], references: [tag])
            ])
        let resolved = await ClientContainerService.resolveAncestorFilter([tag], with: resolver)
        let containers = [
            try makeSnapshot(id: "old", image: tag, imageDigest: oldDigest),
            try makeSnapshot(id: "new", image: tag, imageDigest: newDigest),
        ]

        let result = ClientContainerService.applyFilters(
            containers,
            filters: ["ancestor": [tag]],
            resolvedAncestors: resolved
        )

        #expect(result.map(\.id) == ["new"])
    }

    // MARK: - unknown key

    @Test("unknown filter key is ignored — all containers pass")
    func unknownKey() throws {
        let containers = [try makeSnapshot(id: "a"), try makeSnapshot(id: "b")]
        let result = ClientContainerService.applyFilters(
            containers, filters: ["nonexistent": ["value"]])
        #expect(result.count == 2)
    }

    // MARK: - empty filters

    @Test("empty filters dict returns all containers unchanged")
    func emptyFilters() throws {
        let containers = [try makeSnapshot(id: "a"), try makeSnapshot(id: "b")]
        let result = ClientContainerService.applyFilters(containers, filters: [:])
        #expect(result.count == 2)
    }

    // MARK: - network

    @Test("network filter keeps containers attached to the named network")
    func networkFilter() throws {
        let containers = [
            try makeSnapshot(id: "a", networkNames: ["mynet", "bridge"]),
            try makeSnapshot(id: "b", networkNames: ["other"]),
            try makeSnapshot(id: "c"),  // no networks
        ]
        let result = ClientContainerService.applyFilters(
            containers, filters: ["network": ["mynet"]])
        #expect(result.map(\.id) == ["a"])
    }

    // MARK: - exited key filter (distinct from status=exited)

    @Test("exited=0 filter keeps stopped containers (exit code 0 is the only tracked state)")
    func exitedKeyFilter() throws {
        let containers = [
            try makeSnapshot(id: "a", status: .stopped),
            try makeSnapshot(id: "b", status: .running),
        ]
        let result = ClientContainerService.applyFilters(containers, filters: ["exited": ["0"]])
        #expect(result.map(\.id) == ["a"])
    }

    @Test("exited=1 excludes all containers (only exited=0 or empty passes the filter)")
    func exitedNonZeroKey() throws {
        let containers = [try makeSnapshot(id: "a", status: .stopped)]
        let result = ClientContainerService.applyFilters(containers, filters: ["exited": ["1"]])
        #expect(result.isEmpty)
    }

    // MARK: - id prefix match

    @Test("id filter matches truncated hex ID prefix")
    func idPrefixMatch() throws {
        let container = try makeSnapshot(id: "my-container")
        let hexId = DockerContainerID.hexId(for: container)
        let prefix = String(hexId.prefix(12))  // docker ps shows first 12 chars

        let result = ClientContainerService.applyFilters(
            [container, try makeSnapshot(id: "other")],
            filters: ["id": [prefix]])
        #expect(result.map(\.id) == ["my-container"])
    }

    // MARK: - label normalization

    @Test("label filter with mixed-case key matches normalized stored label")
    func labelNormalization() throws {
        // Labels are stored normalized (MyApp → myapp); filterValue handles the lookup.
        let containers = [
            try makeSnapshot(id: "a", labels: LabelNormalization.sanitize(["MyApp": "test"]))
        ]
        let result = ClientContainerService.applyFilters(
            containers, filters: ["label": ["myapp=test"]])
        #expect(result.map(\.id) == ["a"])
    }

    @Test("internal image attribution labels are not visible to Docker label filters")
    func hiddenImageIdentityLabelsDoNotMatch() throws {
        let containers = [
            try makeSnapshot(
                id: "a",
                labels: [
                    "visible": "yes",
                    ContainerImageIdentity.requestedReferenceLabel:
                        "example:latest",
                    ContainerImageIdentity.configDigestLabel:
                        "sha256:" + String(repeating: "a", count: 64),
                ]
            )
        ]

        let visible = ClientContainerService.applyFilters(
            containers,
            filters: ["label": ["visible=yes"]]
        )
        let requestedIdentity = ClientContainerService.applyFilters(
            containers,
            filters: [
                "label": [ContainerImageIdentity.requestedReferenceLabel]
            ]
        )
        let digestIdentity = ClientContainerService.applyFilters(
            containers,
            filters: ["label": [ContainerImageIdentity.configDigestLabel]]
        )

        #expect(visible.map(\.id) == ["a"])
        #expect(requestedIdentity.isEmpty)
        #expect(digestIdentity.isEmpty)
    }

    // MARK: - volume stub

    @Test("volume filter always returns empty (not implemented)")
    func volumeFilterStub() throws {
        let containers = [try makeSnapshot(id: "a"), try makeSnapshot(id: "b")]
        let result = ClientContainerService.applyFilters(
            containers, filters: ["volume": ["some-vol"]])
        #expect(result.isEmpty)
    }

    // MARK: - before / since (fallback: lexicographic id ordering when no timestamp)

    @Test("before=c keeps containers whose id comes before 'c' lexicographically")
    func beforeFilter() throws {
        // Without timestamps, before/since fall back to lexicographic id comparison.
        let containers = [
            try makeSnapshot(id: "aaa"),
            try makeSnapshot(id: "bbb"),
            try makeSnapshot(id: "ccc"),
            try makeSnapshot(id: "ddd"),
        ]
        let result = ClientContainerService.applyFilters(
            containers, filters: ["before": ["ccc"]], allContainers: containers)
        #expect(result.map(\.id) == ["aaa", "bbb"])
    }

    @Test("before= with hex ID prefix resolves correctly")
    func beforeFilterHexPrefix() throws {
        let ref = try makeSnapshot(id: "ccc")
        let hexPrefix = String(DockerContainerID.hexId(for: ref).prefix(12))
        let containers = [try makeSnapshot(id: "aaa"), ref, try makeSnapshot(id: "ddd")]
        let result = ClientContainerService.applyFilters(
            containers, filters: ["before": [hexPrefix]], allContainers: containers)
        #expect(result.map(\.id) == ["aaa"])
    }

    @Test("since=a keeps containers whose id comes after 'a' lexicographically")
    func sinceFilter() throws {
        let containers = [
            try makeSnapshot(id: "aaa"),
            try makeSnapshot(id: "bbb"),
            try makeSnapshot(id: "ccc"),
        ]
        let result = ClientContainerService.applyFilters(
            containers, filters: ["since": ["aaa"]], allContainers: containers)
        #expect(result.map(\.id) == ["bbb", "ccc"])
    }

    // MARK: - remaining filter keys (behavioural smoke tests)

    @Test("name filter keeps containers matching by native id")
    func nameFilter() throws {
        let containers = [try makeSnapshot(id: "my-ctr"), try makeSnapshot(id: "other")]
        let result = ClientContainerService.applyFilters(containers, filters: ["name": ["my-ctr"]])
        #expect(result.map(\.id) == ["my-ctr"])
    }

    @Test("is-task filter keeps containers with swarm task label")
    func isTaskFilter() throws {
        let containers = [
            try makeSnapshot(id: "a", labels: ["com.docker.swarm.task.id": "xyz"]),
            try makeSnapshot(id: "b"),
        ]
        let result = ClientContainerService.applyFilters(containers, filters: ["is-task": ["true"]])
        #expect(result.map(\.id) == ["a"])
    }

    @Test("isolation filter keeps linux containers when filter=process")
    func isolationFilter() throws {
        let containers = [try makeSnapshot(id: "a")]  // platform.os defaults to "linux"
        let result = ClientContainerService.applyFilters(
            containers, filters: ["isolation": ["process"]])
        #expect(result.map(\.id) == ["a"])
    }

    // MARK: - combined

    @Test("status and label filters are ANDed across keys")
    func combinedFilters() throws {
        let containers = [
            try makeSnapshot(id: "a", status: .running, labels: ["env": "prod"]),
            try makeSnapshot(id: "b", status: .running, labels: ["env": "dev"]),
            try makeSnapshot(id: "c", status: .stopped, labels: ["env": "prod"]),
        ]
        let result = ClientContainerService.applyFilters(
            containers, filters: ["status": ["running"], "label": ["env=prod"]])
        #expect(result.map(\.id) == ["a"])
    }
}

private struct StubImageReferenceResolver: ImageReferenceResolving {
    let identitiesByIdentifier: [String: ResolvedImageFilterIdentity]

    func identity(for identifier: String) async throws -> ResolvedImageFilterIdentity {
        guard let identity = identitiesByIdentifier[identifier] else {
            throw ImageIdentityResolutionError.notFound(identifier)
        }
        return identity
    }
}

// MARK: - Helpers

private func makeSnapshot(
    id: String,
    status: RuntimeStatus = .running,
    labels: [String: String] = [:],
    image: String = "alpine:latest",
    imageDigest: String = "sha256:abc",
    networkNames: [String] = []
) throws -> ContainerSnapshot {
    let proc = ProcessConfiguration(
        executable: "/bin/sh", arguments: [], environment: [],
        workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
    let img = ImageDescription(
        reference: image,
        descriptor: Descriptor(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest: imageDigest, size: 0))
    var config = ContainerConfiguration(id: id, image: img, process: proc)
    config.labels = labels
    let attachments = try networkNames.map { try makeAttachment(network: $0) }
    return ContainerSnapshot(configuration: config, status: status, networks: attachments)
}

private func makeAttachment(network: String) throws -> ContainerResource.Attachment {
    ContainerResource.Attachment(
        network: network, hostname: "host",
        ipv4Address: try CIDRv4("192.168.1.2/24"),
        ipv4Gateway: try IPv4Address("192.168.1.1"),
        ipv6Address: nil, macAddress: nil)
}
