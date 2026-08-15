import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Testing

@testable import GlassDock

@Suite("Container image identity joins")
struct ContainerImageIdentityTests {
    @Test("tag replacement attributes containers to immutable roots")
    func replacementUsesDigest() throws {
        let oldDigest = "sha256:" + String(repeating: "1", count: 64)
        let newDigest = "sha256:" + String(repeating: "2", count: 64)
        let tag = "docker.io/library/example:latest"
        let containers = [
            try snapshot(id: "old", reference: tag, digest: oldDigest),
            try snapshot(id: "new", reference: tag, digest: newDigest),
        ]

        let usage = ContainerImageIdentity.usageByRootDigest(containers)

        #expect(usage[oldDigest] == 1)
        #expect(usage[newDigest] == 1)
        #expect(ContainerImageIdentity.containers(containers, usingRootDigest: oldDigest).map(\.id) == ["old"])
        #expect(ContainerImageIdentity.containers(containers, usingRootDigest: newDigest).map(\.id) == ["new"])
    }

    @Test("disk usage maps an old container root to its dangling store reference")
    func activeReferencesUseRetainingRoot() throws {
        let oldDigest = "sha256:" + String(repeating: "3", count: 64)
        let newDigest = "sha256:" + String(repeating: "4", count: 64)
        let tag = "docker.io/library/example:latest"
        let containers = [try snapshot(id: "old", reference: tag, digest: oldDigest)]

        let references = ContainerImageIdentity.activeStoreReferences(
            physicalReferencesByRootDigest: [
                oldDigest: ["moby-dangling@\(oldDigest)"],
                newDigest: [tag],
            ],
            containers: containers
        )

        #expect(references == ["moby-dangling@\(oldDigest)"])
    }

    @Test("disk usage retains exact familiar and masked physical keys")
    func activeReferencesUsePhysicalKeys() throws {
        let oldDigest = "sha256:" + String(repeating: "5", count: 64)
        let newDigest = "sha256:" + String(repeating: "6", count: 64)
        let familiar = "example:latest"
        let canonical = "docker.io/library/example:latest"
        let containers = [
            try snapshot(id: "legacy", reference: familiar, digest: oldDigest)
        ]

        let references = ContainerImageIdentity.activeStoreReferences(
            physicalReferencesByRootDigest: [
                oldDigest: [familiar],
                newDigest: [canonical],
            ],
            containers: containers
        )

        #expect(references == [familiar])
        #expect(!references.contains(canonical))
    }

    @Test("container display preserves the exact Docker request after a tag moves")
    func containerDisplayPreservesRequestedReference() async throws {
        let oldRoot = "sha256:" + String(repeating: "7", count: 64)
        let newRoot = "sha256:" + String(repeating: "8", count: 64)
        let configDigest = "sha256:" + String(repeating: "a", count: 64)
        let tag = "docker.io/library/example:latest"
        let container = try snapshot(
            id: "old",
            reference: tag,
            digest: oldRoot
        )
        let currentProvider = CanonicalContainerImageMetadataProvider(
            resolver: StubRootResolver(roots: [tag: oldRoot]),
            configDigestProvider: { _ in configDigest }
        )
        let movedProvider = CanonicalContainerImageMetadataProvider(
            resolver: StubRootResolver(roots: [tag: newRoot]),
            configDigestProvider: { _ in configDigest }
        )
        let deletedProvider = CanonicalContainerImageMetadataProvider(
            resolver: StubRootResolver(roots: [:]),
            configDigestProvider: { _ in configDigest }
        )

        #expect(
            await currentProvider.metadata(for: container).displayReference
                == tag
        )
        #expect(
            await movedProvider.metadata(for: container).displayReference
                == tag
        )
        #expect(
            await deletedProvider.metadata(for: container).displayReference
                == tag
        )
    }

    @Test("all Docker identifier spellings round-trip independently of the runtime lease")
    func requestedIdentifierFormsRoundTrip() throws {
        let rootDigest = "sha256:" + String(repeating: "b", count: 64)
        let configDigest = "sha256:" + String(repeating: "c", count: 64)
        let manifestDigest = "sha256:" + String(repeating: "d", count: 64)
        let runtimeReference = ContainerImageLease.reference(for: rootDigest)
        let requestedForms = [
            "example:latest",
            rootDigest,
            manifestDigest,
            configDigest,
        ]

        for (index, requested) in requestedForms.enumerated() {
            var container = try snapshot(
                id: "identifier-\(index)",
                reference: runtimeReference,
                digest: rootDigest
            )
            container.configuration.labels = [
                "user.label": "visible",
                ContainerImageIdentity.requestedReferenceLabel: requested,
                ContainerImageIdentity.configDigestLabel: configDigest,
            ]

            #expect(
                ContainerImageIdentity.requestedReference(for: container)
                    == requested
            )
            #expect(
                ContainerImageIdentity.dockerLabels(for: container)
                    == ["user.label": "visible"]
            )
            #expect(
                container.configuration.image.reference == runtimeReference
            )
        }
    }

    @Test("container identity labels reject direct and normalized user spoofing")
    func identityLabelsAreReservedForContainers() {
        #expect(
            ContainerImageIdentity.reservedUserLabel(in: [
                ContainerImageIdentity.requestedReferenceLabel: "spoof"
            ]) == ContainerImageIdentity.requestedReferenceLabel
        )
        #expect(
            ContainerImageIdentity.reservedUserLabel(in: [
                "GLASSDOCK.IMAGE.CONFIG-DIGEST": "spoof"
            ]) == "GLASSDOCK.IMAGE.CONFIG-DIGEST"
        )
        #expect(
            ContainerImageIdentity.reservedUserLabel(in: [
                ContainerImageIdentity.instanceOwnerLabel: "spoof"
            ]) == ContainerImageIdentity.instanceOwnerLabel
        )
    }

    @Test("container-specific label names remain valid on non-container resources")
    func identityLabelsAreNotGloballyStripped() {
        let labels = [
            ContainerImageIdentity.requestedReferenceLabel: "ordinary-value",
            ContainerImageIdentity.configDigestLabel: "ordinary-digest",
        ]
        #expect(LabelNormalization.reservedKey(in: labels) == nil)
        #expect(LabelNormalization.restore(labels) == labels)
    }

    private func snapshot(id: String, reference: String, digest: String) throws -> ContainerSnapshot {
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
        let image = ImageDescription(
            reference: reference,
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: digest,
                size: 0
            )
        )
        return ContainerSnapshot(
            configuration: ContainerConfiguration(id: id, image: image, process: process),
            status: .running,
            networks: []
        )
    }
}

private struct StubRootResolver: ImageReferenceResolving {
    let roots: [String: String]

    func identity(for identifier: String) async throws -> ResolvedImageFilterIdentity {
        guard let root = roots[identifier] else {
            throw ImageIdentityResolutionError.notFound(identifier)
        }
        return ResolvedImageFilterIdentity(
            rootDigests: [root],
            references: [identifier]
        )
    }
}
