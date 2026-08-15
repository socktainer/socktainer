import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress
import Testing

@testable import GlassDock

@Suite("Canonical image reference manager")
struct CanonicalImageReferenceManagerTests {
    private static let familiar = "example:latest"
    private static let canonical = "docker.io/library/example:latest"

    @Test("replacing a last tag preserves the old root and removes its familiar alias")
    func replacingLastTagPreservesOldRoot() async throws {
        let old = Self.image(reference: Self.familiar, digestCharacter: "a")
        let replacement = Self.image(reference: Self.familiar, digestCharacter: "b")
        let store = FakeImageReferenceStore([old])
        let manager = Self.manager(store: store)

        let prepared = try await manager.prepareToReplace([Self.familiar])
        await store.put(replacement)
        try await manager.commit(
            [CanonicalImageAssignment(targetReference: Self.familiar, image: replacement)],
            prepared: prepared
        )

        let images = await store.imagesByReference()
        #expect(images[Self.canonical]?.digest == replacement.digest)
        #expect(images[Self.familiar] == nil)
        #expect(images[Self.dangling(old.digest)]?.digest == old.digest)
    }

    @Test("a rebuilt familiar key atomically replaces an older canonical owner")
    func rebuiltFamiliarKeyReplacesCanonicalOwner() async throws {
        let old = Self.image(reference: Self.canonical, digestCharacter: "a")
        let replacement = Self.image(
            reference: Self.familiar,
            digestCharacter: "b"
        )
        let store = FakeImageReferenceStore([old])
        let manager = Self.manager(store: store)

        let prepared = try await manager.prepareToReplace([Self.canonical])
        await store.put(replacement)
        try await manager.commit(
            [
                CanonicalImageAssignment(
                    targetReference: Self.canonical,
                    image: replacement
                )
            ],
            prepared: prepared
        )

        let images = await store.imagesByReference()
        #expect(images[Self.canonical]?.digest == replacement.digest)
        #expect(images[Self.familiar] == nil)
        #expect(images[Self.dangling(old.digest)]?.digest == old.digest)
        #expect(
            manager.dockerVisibleImages(Array(images.values)).filter {
                $0.reference == Self.canonical
            }.count == 1
        )
    }

    @Test("an old root with another real tag does not need a dangling reference")
    func anotherRealTagAvoidsDanglingReference() async throws {
        let old = Self.image(reference: Self.familiar, digestCharacter: "a")
        let retained = Self.image(
            reference: "docker.io/library/example:retained",
            digestCharacter: "a"
        )
        let replacement = Self.image(reference: Self.familiar, digestCharacter: "b")
        let store = FakeImageReferenceStore([old, retained])
        let manager = Self.manager(store: store)

        let prepared = try await manager.prepareToReplace([Self.familiar])
        await store.put(replacement)
        try await manager.commit(
            [CanonicalImageAssignment(targetReference: Self.familiar, image: replacement)],
            prepared: prepared
        )

        let images = await store.imagesByReference()
        #expect(images[Self.canonical]?.digest == replacement.digest)
        #expect(images[Self.familiar] == nil)
        #expect(images[retained.reference]?.digest == old.digest)
        #expect(images[Self.dangling(old.digest)] == nil)
    }

    @Test("same-root replacement removes both the familiar alias and redundant preservation")
    func sameRootReplacementCleansUp() async throws {
        let old = Self.image(reference: Self.familiar, digestCharacter: "a")
        let replacement = Self.image(reference: Self.familiar, digestCharacter: "a")
        let store = FakeImageReferenceStore([old])
        let manager = Self.manager(store: store)

        let prepared = try await manager.prepareToReplace([Self.familiar])
        await store.put(replacement)
        try await manager.commit(
            [CanonicalImageAssignment(targetReference: Self.canonical, image: replacement)],
            prepared: prepared
        )

        let images = await store.imagesByReference()
        #expect(images[Self.canonical]?.digest == old.digest)
        #expect(images[Self.familiar] == nil)
        #expect(images[Self.dangling(old.digest)] == nil)
        #expect(images.count == 1)
    }

    @Test("rollback removes a preservation reference when the original tag still exists")
    func rollbackRemovesRedundantPreservation() async throws {
        let old = Self.image(reference: Self.familiar, digestCharacter: "a")
        let store = FakeImageReferenceStore([old])
        let manager = Self.manager(store: store)

        let prepared = try await manager.prepareToReplace([Self.familiar])
        #expect(await store.image(reference: Self.dangling(old.digest)) != nil)

        await manager.rollback(prepared)

        let images = await store.imagesByReference()
        #expect(images[Self.familiar]?.digest == old.digest)
        #expect(images[Self.dangling(old.digest)] == nil)
        #expect(images.count == 1)
    }

    @Test("rollback restores an exact owner overwritten before an operation fails")
    func rollbackRestoresOverwrittenCanonicalOwner() async throws {
        let old = Self.image(reference: Self.canonical, digestCharacter: "a")
        let replacement = Self.image(
            reference: Self.canonical,
            digestCharacter: "b"
        )
        let store = FakeImageReferenceStore([old])
        let manager = Self.manager(store: store)

        let prepared = try await manager.prepareToReplace([Self.familiar])
        await store.put(replacement)
        await manager.rollback(prepared)

        let images = await store.imagesByReference()
        #expect(images[Self.canonical]?.digest == old.digest)
        #expect(images[Self.dangling(old.digest)] == nil)
        #expect(images.count == 1)
    }

    @Test("rollback removes a canonical key created over a familiar-only owner")
    func rollbackRemovesNewCanonicalKey() async throws {
        let old = Self.image(reference: Self.familiar, digestCharacter: "a")
        let replacement = Self.image(
            reference: Self.canonical,
            digestCharacter: "b"
        )
        let store = FakeImageReferenceStore([old])
        let manager = Self.manager(store: store)

        let prepared = try await manager.prepareToReplace([Self.familiar])
        await store.put(replacement)
        await manager.rollback(prepared)

        let images = await store.imagesByReference()
        #expect(images[Self.familiar]?.digest == old.digest)
        #expect(images[Self.canonical] == nil)
        #expect(images[Self.dangling(old.digest)] == nil)
    }

    @Test("a cancelled partial prepare removes every preservation marker")
    func cancelledPartialPrepareRestoresExactPreState() async throws {
        let first = Self.image(
            reference: Self.familiar,
            digestCharacter: "a"
        )
        let second = Self.image(
            reference: "second:latest",
            digestCharacter: "b"
        )
        let store = FakeImageReferenceStore(
            [first, second],
            cancellationAwareOperations: true
        )
        await store.cancelNextTag(new: Self.dangling(second.digest))
        let manager = Self.manager(store: store)

        let attempt = Task {
            try await manager.prepareToReplace([
                Self.familiar, second.reference,
            ])
        }
        await #expect(throws: CancellationError.self) {
            try await attempt.value
        }

        let images = await store.imagesByReference()
        #expect(images[first.reference]?.digest == first.digest)
        #expect(images[second.reference]?.digest == second.digest)
        #expect(images[Self.dangling(first.digest)] == nil)
        #expect(images[Self.dangling(second.digest)] == nil)
        #expect(images.count == 2)
    }

    @Test("a preservation tag committed before an XPC error is rolled back")
    func committedPreservationTagIsRolledBackAfterError() async throws {
        let old = Self.image(
            reference: Self.familiar,
            digestCharacter: "a"
        )
        let store = FakeImageReferenceStore([old])
        await store.commitThenFailNextTag(new: Self.dangling(old.digest))
        let manager = Self.manager(store: store)

        await #expect(throws: FakeStoreError.injected) {
            try await manager.prepareToReplace([Self.familiar])
        }

        let images = await store.imagesByReference()
        #expect(images[old.reference]?.digest == old.digest)
        #expect(images[Self.dangling(old.digest)] == nil)
        #expect(images.count == 1)
    }

    @Test("replacing a legacy annotation owner prevents later tag resurrection")
    func legacyAnnotationOwnerIsRetired() async throws {
        let old = Self.image(
            reference: "untagged@sha256:" + String(repeating: "a", count: 64),
            digestCharacter: "a",
            annotatedName: Self.familiar
        )
        let replacement = Self.image(
            reference: Self.canonical,
            digestCharacter: "b"
        )
        let store = FakeImageReferenceStore([old])
        let manager = Self.manager(store: store)

        let prepared = try await manager.prepareToReplace([Self.familiar])
        await store.put(replacement)
        try await manager.commit(
            [
                CanonicalImageAssignment(
                    targetReference: Self.familiar,
                    image: replacement,
                )
            ],
            prepared: prepared
        )

        let images = await store.imagesByReference()
        #expect(images[Self.canonical]?.digest == replacement.digest)
        #expect(images[old.reference] == nil)
        #expect(images[Self.dangling(old.digest)]?.digest == old.digest)
    }

    @Test("a pre-existing crash marker is tracked and cleaned on same-root recovery")
    func existingPreservationReferenceIsReconciled() async throws {
        let old = Self.image(reference: Self.familiar, digestCharacter: "a")
        let marker = Self.image(
            reference: Self.dangling(old.digest),
            digestCharacter: "a"
        )
        let replacement = Self.image(
            reference: Self.canonical,
            digestCharacter: "a"
        )
        let store = FakeImageReferenceStore([old, marker])
        let manager = Self.manager(store: store)

        let prepared = try await manager.prepareToReplace([Self.familiar])
        await store.put(replacement)
        try await manager.commit(
            [
                CanonicalImageAssignment(
                    targetReference: Self.canonical,
                    image: replacement,
                )
            ],
            prepared: prepared
        )

        let images = await store.imagesByReference()
        #expect(images[Self.canonical]?.digest == old.digest)
        #expect(images[Self.familiar] == nil)
        #expect(images[Self.dangling(old.digest)] == nil)
    }

    @Test("logical removal preserves stale roots and commits with the canonical key last")
    func logicalRemovalKeepsAuthoritativeOwnerUntilCommit() async throws {
        let stale = Self.image(reference: Self.familiar, digestCharacter: "a")
        let owner = Self.image(reference: Self.canonical, digestCharacter: "b")
        let redundantOwnerMarker = Self.image(
            reference: Self.dangling(owner.digest),
            digestCharacter: "b"
        )
        let store = FakeImageReferenceStore([
            stale, owner, redundantOwnerMarker,
        ])
        let manager = Self.manager(store: store)

        _ = try await manager.prepareToRemove(
            Self.familiar,
            currentOwnerDigest: owner.digest
        )
        let ordered = try await manager.physicalReferences(
            claiming: Self.familiar
        )

        #expect(ordered == [Self.familiar, Self.canonical])
        #expect(await store.image(reference: Self.dangling(stale.digest)) != nil)
        #expect(await store.image(reference: Self.dangling(owner.digest)) == nil)
    }

    @Test("every partial logical-remove failure leaves the authoritative key present")
    func logicalRemoveFailureCannotSwitchOwner() async throws {
        for failureOffset in 0...1 {
            let stale = Self.image(reference: Self.familiar, digestCharacter: "a")
            let owner = Self.image(reference: Self.canonical, digestCharacter: "b")
            let store = FakeImageReferenceStore([stale, owner])
            let manager = Self.manager(store: store)
            _ = try await manager.prepareToRemove(
                Self.familiar,
                currentOwnerDigest: owner.digest
            )
            let ordered = try await manager.physicalReferences(
                claiming: Self.familiar
            )

            for (offset, reference) in ordered.enumerated() {
                if offset == failureOffset { break }
                try await store.delete(reference: reference)
            }

            #expect(await store.image(reference: Self.canonical)?.digest == owner.digest)
        }
    }

    @Test("a failed alias cleanup rolls back both the owner and preservation marker")
    func failedCommitRollsBack() async throws {
        let old = Self.image(reference: Self.familiar, digestCharacter: "a")
        let replacement = Self.image(
            reference: Self.canonical,
            digestCharacter: "b"
        )
        let store = FakeImageReferenceStore([old])
        let manager = Self.manager(store: store)
        let prepared = try await manager.prepareToReplace([Self.familiar])
        await store.put(replacement)
        await store.failNextDelete(reference: Self.familiar)

        await #expect(throws: FakeStoreError.injected) {
            try await manager.commit(
                [
                    CanonicalImageAssignment(
                        targetReference: Self.canonical,
                        image: replacement,
                    )
                ],
                prepared: prepared
            )
        }
        await manager.rollback(prepared)

        let images = await store.imagesByReference()
        #expect(images[Self.familiar]?.digest == old.digest)
        #expect(images[Self.canonical] == nil)
        #expect(images[Self.dangling(old.digest)] == nil)
    }

    @Test("missing and conflicting replacement assignments fail before ownership changes")
    func invalidAssignmentsAreRejected() async throws {
        let old = Self.image(reference: Self.familiar, digestCharacter: "a")
        let other = Self.image(reference: Self.canonical, digestCharacter: "b")
        let store = FakeImageReferenceStore([old])
        let manager = Self.manager(store: store)
        let prepared = try await manager.prepareToReplace([Self.familiar])

        await #expect(
            throws: CanonicalImageReferenceError.assignmentMissing(
                target: Self.canonical
            )
        ) {
            try await manager.commit([], prepared: prepared)
        }
        await #expect(
            throws: CanonicalImageReferenceError.conflictingAssignments(
                target: Self.canonical
            )
        ) {
            try await manager.commit(
                [
                    CanonicalImageAssignment(
                        targetReference: Self.familiar,
                        image: old
                    ),
                    CanonicalImageAssignment(
                        targetReference: Self.canonical,
                        image: other
                    ),
                ],
                prepared: prepared
            )
        }
        await manager.rollback(prepared)
    }

    @Test("the Docker-visible view has one owner when canonical and familiar keys disagree")
    func dockerVisibleViewHasSingleOwner() async throws {
        let stale = Self.image(reference: Self.familiar, digestCharacter: "a")
        let owner = Self.image(reference: Self.canonical, digestCharacter: "b")
        let unrelated = Self.image(
            reference: "docker.io/library/unrelated:latest",
            digestCharacter: "c"
        )
        let manager = Self.manager(store: FakeImageReferenceStore([]))

        let visible = manager.dockerVisibleImages([stale, owner, unrelated])
        let targetImages = visible.filter { $0.reference == Self.canonical }

        #expect(targetImages.count == 1)
        #expect(targetImages.first?.digest == owner.digest)
        #expect(visible.contains { $0.reference == unrelated.reference })
        #expect(!visible.contains { $0.digest == stale.digest })
    }

    @Test("a runtime lease never duplicates the tagged Docker row for its root")
    func dockerVisibleViewCoalescesTagAndRuntimeLease() {
        let tagged = Self.image(
            reference: Self.canonical,
            digestCharacter: "b"
        )
        let lease = Self.image(
            reference: ContainerImageLease.reference(for: tagged.digest),
            digestCharacter: "b"
        )
        let manager = Self.manager(store: FakeImageReferenceStore([]))

        let visible = manager.dockerVisibleImages(
            [tagged, lease],
            activeLeaseRootDigests: [tagged.digest]
        )

        #expect(visible.count == 1)
        #expect(visible.first?.reference == Self.canonical)
        #expect(visible.first?.digest == tagged.digest)
    }

    @Test("an active lease-only root becomes one anonymous Docker row without exposing the internal key")
    func dockerVisibleViewSynthesizesActiveLeaseOnlyRoot() {
        let lease = Self.image(
            reference: ContainerImageLease.reference(
                for: "sha256:" + String(repeating: "8", count: 64)
            ),
            digestCharacter: "8"
        )
        let manager = Self.manager(store: FakeImageReferenceStore([]))

        let visible = manager.dockerVisibleImages(
            [lease],
            activeLeaseRootDigests: [lease.digest]
        )
        let staleVisible = manager.dockerVisibleImages([lease])

        #expect(visible.count == 1)
        #expect(visible.first?.reference == lease.digest)
        #expect(!ContainerImageLease.isReference(visible[0].reference))
        #expect(staleVisible.isEmpty)
    }

    @Test("the Docker-visible view restores a legacy annotation-only tag")
    func dockerVisibleViewRestoresLegacyAnnotationOwner() async throws {
        let legacy = Self.image(
            reference: "untagged@sha256:" + String(repeating: "a", count: 64),
            digestCharacter: "a",
            annotatedName: Self.familiar
        )
        let store = FakeImageReferenceStore([legacy])
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            referenceStore: store
        )

        let visible = try await service.list()

        #expect(visible.count == 1)
        #expect(visible.first?.reference == Self.canonical)
        #expect(visible.first?.digest == legacy.digest)
        #expect(!ClientImageService.isDockerDanglingReference(visible[0].reference))
    }

    @Test("a bare physical digest remains an immutable ID rather than becoming a tag")
    func dockerVisibleViewPreservesBareDigestIdentity() async throws {
        let bareDigest = "sha256:" + String(repeating: "d", count: 64)
        let image = Self.image(
            reference: bareDigest,
            digestCharacter: "d"
        )
        let manager = Self.manager(store: FakeImageReferenceStore([image]))

        #expect(manager.canonicalTag(bareDigest) == nil)
        let visible = manager.dockerVisibleImages([image])
        #expect(visible.count == 1)
        #expect(visible.first?.reference == bareDigest)
        #expect(visible.first?.digest == bareDigest)

        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            referenceStore: FakeImageReferenceStore([image])
        )
        let listed = try await service.list()
        #expect(listed.count == 1)
        #expect(listed.first?.reference == bareDigest)
    }

    @Test("the image service tags over an occupied target through canonical replacement")
    func serviceTagReplacesOccupiedTarget() async throws {
        let source = Self.image(
            reference: "docker.io/library/source:latest",
            digestCharacter: "a"
        )
        let oldTarget = Self.image(
            reference: Self.familiar,
            digestCharacter: "b"
        )
        let store = FakeImageReferenceStore([source, oldTarget])
        let catalog = StaticImageIdentityCatalog([source, oldTarget])
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: catalog,
            mutationCoordinator: coordinator
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store
        )

        let tagged = try await service.tag(
            source: "source",
            target: Self.familiar
        )

        let images = await store.imagesByReference()
        #expect(tagged.image.reference == Self.canonical)
        #expect(images[Self.canonical]?.digest == source.digest)
        #expect(images[Self.familiar] == nil)
        #expect(images[Self.dangling(oldTarget.digest)]?.digest == oldTarget.digest)
    }

    @Test("the pull path atomically replaces an occupied familiar target")
    func servicePullReplacesOccupiedTarget() async throws {
        let oldTarget = Self.image(
            reference: Self.familiar,
            digestCharacter: "b"
        )
        let replacement = Self.image(
            reference: Self.canonical,
            digestCharacter: "a"
        )
        let store = FakeImageReferenceStore([oldTarget])
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            referenceStore: store,
            imagePuller: FakeImagePuller(
                image: replacement,
                store: store
            )
        )

        let progress = try await service.pull(
            image: "example",
            tag: "latest",
            platform: Platform(arch: "arm64", os: "linux"),
            fallbackPolicy: .allowRosetta,
            logger: Logger(label: "test")
        )
        for try await _ in progress {}

        let images = await store.imagesByReference()
        #expect(images[Self.canonical]?.digest == replacement.digest)
        #expect(images[Self.familiar] == nil)
        #expect(images[Self.dangling(oldTarget.digest)]?.digest == oldTarget.digest)
    }

    @Test("pull progress reports the config identity captured at canonical commit")
    func servicePullReportsCommittedConfigIdentity() async throws {
        let replacement = Self.image(
            reference: Self.canonical,
            digestCharacter: "a"
        )
        let store = FakeImageReferenceStore([])
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: store,
            mutationCoordinator: coordinator
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store,
            imagePuller: FakeImagePuller(image: replacement, store: store)
        )

        let progress = try await service.pull(
            image: "example",
            tag: "latest",
            platform: Platform(arch: "arm64", os: "linux"),
            fallbackPolicy: .strict,
            logger: Logger(label: "pull-identity-test")
        )
        var messages: [String] = []
        for try await event in progress {
            if case .message(let message) = event { messages.append(message) }
        }

        let expected = RunnableCatalogFixture.configDigest(
            for: replacement.digest
        )
        #expect(messages.contains("Image digest: \(expected)"))
        #expect(!messages.contains("Image digest: \(replacement.digest)"))
    }

    @Test("a single-manifest pull persists the distribution manifest digest")
    func singleManifestPullPersistsDistributionDigest() async throws {
        let reference = "registry.example.test/team/example:qa"
        let replacement = Self.image(
            reference: reference,
            digestCharacter: "c"
        )
        let distributionDigest = RunnableCatalogFixture.manifestDigest(
            for: replacement.digest
        )
        let repositoryDigest =
            "registry.example.test/team/example@\(distributionDigest)"
        let store = FakeImageReferenceStore([])
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: store,
            mutationCoordinator: coordinator
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store,
            imagePuller: FakeImagePuller(
                image: replacement,
                store: store,
                distributionDigest: distributionDigest
            )
        )

        let progress = try await service.pull(
            image: "registry.example.test/team/example",
            tag: "qa",
            platform: Platform(arch: "arm64", os: "linux"),
            fallbackPolicy: .strict,
            logger: Logger(label: "registry-pull-identity-test")
        )
        for try await _ in progress {}

        let images = await store.imagesByReference()
        #expect(images[reference]?.digest == replacement.digest)
        #expect(images[repositoryDigest]?.digest == replacement.digest)

        let byTag = try await resolver.resolve(reference)
        #expect(byTag.repositoryDigests == [repositoryDigest])
        #expect(byTag.image.digest == replacement.digest)

        let byDigest = try await resolver.resolve(repositoryDigest)
        #expect(byDigest.repositoryDigests == [repositoryDigest])
        #expect(byDigest.image.digest == replacement.digest)
        #expect(
            byDigest.kind
                == .manifest(Platform(arch: "arm64", os: "linux"))
        )
    }

    @Test("a multi-platform pull persists the distribution index digest")
    func indexPullPersistsDistributionDigest() async throws {
        let reference = "registry.example.test/team/indexed:qa"
        let replacement = Self.image(
            reference: reference,
            digestCharacter: "d"
        )
        let repositoryDigest =
            "registry.example.test/team/indexed@\(replacement.digest)"
        let store = FakeImageReferenceStore([])
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: store,
            mutationCoordinator: coordinator
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store,
            imagePuller: FakeImagePuller(image: replacement, store: store)
        )

        let progress = try await service.pull(
            image: "registry.example.test/team/indexed",
            tag: "qa",
            platform: Platform(arch: "arm64", os: "linux"),
            fallbackPolicy: .strict,
            logger: Logger(label: "registry-index-pull-identity-test")
        )
        for try await _ in progress {}

        let byTag = try await resolver.resolve(reference)
        #expect(byTag.repositoryDigests == [repositoryDigest])
        let byDigest = try await resolver.resolve(repositoryDigest)
        #expect(byDigest.image.digest == replacement.digest)
        #expect(byDigest.kind == .root)
    }

    @Test("Apple indirect indexes retain the registry manifest identity")
    func indirectIndexDistributionIdentity() throws {
        let storedDigest = "sha256:" + String(repeating: "a", count: 64)
        let manifestDigest = "sha256:" + String(repeating: "b", count: 64)
        let indirect = Index(
            manifests: [
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: manifestDigest,
                    size: 100,
                    platform: Platform(arch: "arm64", os: "linux")
                )
            ],
            annotations: [AnnotationKeys.containerizationIndexIndirect: "true"]
        )
        #expect(
            try LiveImagePuller.distributionDigest(
                storedDigest: storedDigest,
                index: indirect
            ) == manifestDigest
        )

        let direct = Index(manifests: indirect.manifests)
        #expect(
            try LiveImagePuller.distributionDigest(
                storedDigest: storedDigest,
                index: direct
            ) == storedDigest
        )
    }

    @Test("repository digest installation participates in replacement rollback")
    func repositoryDigestInstallationRollsBack() async throws {
        let old = Self.image(reference: Self.canonical, digestCharacter: "a")
        let replacement = Self.image(
            reference: Self.canonical,
            digestCharacter: "b"
        )
        let repositoryDigest =
            "docker.io/library/example@\(replacement.digest)"
        let store = FakeImageReferenceStore([old])
        let manager = Self.manager(store: store)
        var prepared = try await manager.prepareToReplace([Self.canonical])
        await store.put(replacement)
        let assignments = [
            CanonicalImageAssignment(
                targetReference: Self.canonical,
                image: replacement
            ),
            CanonicalImageAssignment(
                targetReference: repositoryDigest,
                image: replacement
            ),
        ]
        prepared = try await manager.prepareRepositoryDigestAssignments(
            assignments,
            prepared: prepared
        )

        try await manager.commit(assignments, prepared: prepared)
        #expect(
            await store.image(reference: repositoryDigest)?.digest
                == replacement.digest
        )

        await manager.rollback(prepared)
        let images = await store.imagesByReference()
        #expect(images[Self.canonical]?.digest == old.digest)
        #expect(images[repositoryDigest] == nil)
        #expect(images[Self.dangling(old.digest)] == nil)
    }

    @Test("duplicate physical references never trap replacement preparation")
    func duplicatePhysicalReferencesDoNotTrap() async throws {
        let first = Self.image(reference: Self.canonical, digestCharacter: "a")
        let second = Self.image(reference: Self.canonical, digestCharacter: "b")
        let firstAlias = Self.image(reference: "first:latest", digestCharacter: "a")
        let secondAlias = Self.image(reference: "second:latest", digestCharacter: "b")
        let store = DuplicateImageReferenceStore([
            first, second, firstAlias, secondAlias,
        ])
        let manager = CanonicalImageReferenceManager(
            systemConfig: ContainerSystemConfig(),
            store: store
        )

        _ = try await manager.prepareToReplace([Self.canonical])
    }

    @Test("an immutable repository digest never overwrites conflicting ownership")
    func repositoryDigestConflictIsRejected() async throws {
        let existing = Self.image(
            reference:
                "registry.example.test/team/example@sha256:\(String(repeating: "9", count: 64))",
            digestCharacter: "a"
        )
        let replacement = Self.image(
            reference: "replacement:latest",
            digestCharacter: "b"
        )
        let store = DuplicateImageReferenceStore([existing, replacement])
        let manager = CanonicalImageReferenceManager(
            systemConfig: ContainerSystemConfig(),
            store: store
        )
        var prepared = try await manager.prepareToReplace([])
        let assignments = [
            CanonicalImageAssignment(
                targetReference: existing.reference,
                image: replacement
            )
        ]
        prepared = try await manager.prepareRepositoryDigestAssignments(
            assignments,
            prepared: prepared
        )

        do {
            try await manager.commit(assignments, prepared: prepared)
            Issue.record("expected immutable repository digest conflict")
        } catch CanonicalImageReferenceError.conflictingAssignments(let target) {
            #expect(target == existing.reference)
        }
        let owners = try await store.list().filter {
            $0.reference == existing.reference
        }
        #expect(owners.count == 1)
        #expect(owners.first?.digest == existing.digest)
    }

    @Test("a digest pull failure restores an exact key overwritten by Apple")
    func failedDigestPullRestoresPreexistingAssociation() async throws {
        let repositoryDigest =
            "registry.example.test/team/example@sha256:\(String(repeating: "9", count: 64))"
        let existing = Self.image(
            reference: repositoryDigest,
            digestCharacter: "a"
        )
        let replacement = Self.image(
            reference: repositoryDigest,
            digestCharacter: "b"
        )
        let store = FakeImageReferenceStore([existing])
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: store,
            mutationCoordinator: coordinator
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store,
            imagePuller: OverwriteThenFailImagePuller(
                image: replacement,
                store: store
            )
        )

        let progress = try await service.pull(
            image: repositoryDigest,
            tag: nil,
            platform: Platform(arch: "arm64", os: "linux"),
            fallbackPolicy: .strict,
            logger: Logger(label: "failed-digest-pull-rollback-test")
        )
        await #expect(throws: FakeStoreError.self) {
            for try await _ in progress {}
        }

        let images = await store.imagesByReference()
        #expect(images[repositoryDigest]?.digest == existing.digest)
        #expect(images[Self.dangling(existing.digest)] == nil)
    }

    @Test("a digest pull cannot replace an existing immutable association")
    func digestPullCannotReplacePreexistingAssociation() async throws {
        let distributionDigest =
            "sha256:" + String(repeating: "9", count: 64)
        let repositoryDigest =
            "registry.example.test/team/example@\(distributionDigest)"
        let existing = Self.image(
            reference: repositoryDigest,
            digestCharacter: "a"
        )
        let replacement = Self.image(
            reference: repositoryDigest,
            digestCharacter: "b"
        )
        let store = FakeImageReferenceStore([existing])
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: store,
            mutationCoordinator: coordinator
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store,
            imagePuller: FakeImagePuller(
                image: replacement,
                store: store,
                distributionDigest: distributionDigest
            )
        )

        let progress = try await service.pull(
            image: repositoryDigest,
            tag: nil,
            platform: Platform(arch: "arm64", os: "linux"),
            fallbackPolicy: .strict,
            logger: Logger(label: "digest-pull-conflict-test")
        )
        do {
            for try await _ in progress {}
            Issue.record("expected immutable repository digest conflict")
        } catch let error as ClientImageError {
            #expect(
                error.description
                    == "conflict: \(repositoryDigest) has conflicting image assignments"
            )
        }

        let images = await store.imagesByReference()
        #expect(images[repositoryDigest]?.digest == existing.digest)
        #expect(images[Self.dangling(existing.digest)] == nil)
    }

    @Test("a strict arm64 pull never retries amd64")
    func strictPullDoesNotRetryAMD64() async throws {
        let store = FakeImageReferenceStore([])
        let puller = PlatformFallbackImagePuller(
            image: Self.image(
                reference: Self.canonical,
                digestCharacter: "a"
            ),
            store: store
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            referenceStore: store,
            imagePuller: puller
        )
        let progress = try await service.pull(
            image: "example",
            tag: "latest",
            platform: Platform(arch: "arm64", os: "linux"),
            fallbackPolicy: .strict,
            logger: Logger(label: "strict-pull-test")
        )

        do {
            for try await _ in progress {}
            Issue.record("expected strict arm64 pull to fail")
        } catch let error as ContainerizationError {
            #expect(error.code == .unsupported)
        }
        #expect(await puller.requestedArchitectures == ["arm64"])
    }

    @Test("an implicit arm64 pull may retry amd64 for Rosetta")
    func implicitPullMayRetryAMD64() async throws {
        let store = FakeImageReferenceStore([])
        let replacement = Self.image(
            reference: Self.canonical,
            digestCharacter: "a"
        )
        let puller = PlatformFallbackImagePuller(
            image: replacement,
            store: store
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            referenceStore: store,
            imagePuller: puller
        )
        let progress = try await service.pull(
            image: "example",
            tag: "latest",
            platform: Platform(arch: "arm64", os: "linux"),
            fallbackPolicy: .allowRosetta,
            logger: Logger(label: "fallback-pull-test")
        )
        for try await _ in progress {}

        #expect(
            await puller.requestedArchitectures == ["arm64", "amd64"]
        )
        #expect(
            await store.image(reference: Self.canonical)?.digest
                == replacement.digest
        )
    }

    @Test("a cancelled pull that returns after writing rolls back the old tag owner")
    func cancelledPullRollsBackBeforeCommit() async throws {
        let oldTarget = Self.image(
            reference: Self.canonical,
            digestCharacter: "a"
        )
        let replacement = Self.image(
            reference: Self.canonical,
            digestCharacter: "b"
        )
        let replacementWritten = AsyncStream<Void>.makeStream()
        let cancellationObserved = AsyncStream<Void>.makeStream()
        let store = FakeImageReferenceStore(
            [oldTarget],
            cancellationAwareOperations: true
        )
        let coordinator = ImageMutationCoordinator()
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            mutationCoordinator: coordinator,
            referenceStore: store,
            imagePuller: CancellationIgnoringImagePuller(
                image: replacement,
                store: store,
                replacementWritten: replacementWritten.continuation,
                cancellationObserved: cancellationObserved.continuation
            )
        )

        let progress = try await service.pull(
            image: "example",
            tag: "latest",
            platform: Platform(arch: "arm64", os: "linux"),
            fallbackPolicy: .allowRosetta,
            logger: Logger(label: "cancelled-pull-test")
        )
        let consumer = Task {
            do {
                for try await _ in progress {}
            } catch {
                // The mutation's CancellationError is expected on this stream.
            }
        }
        var replacementIterator = replacementWritten.stream.makeAsyncIterator()
        _ = await replacementIterator.next()
        consumer.cancel()
        var cancellationIterator = cancellationObserved.stream.makeAsyncIterator()
        _ = await cancellationIterator.next()

        // Waiting for the next writer proves that the cancelled mutation has
        // completed rollback and released coordinator admission.
        #expect(try await coordinator.performMutation { 42 } == 42)
        _ = await consumer.result

        let images = await store.imagesByReference()
        #expect(images[Self.canonical]?.digest == oldTarget.digest)
        #expect(images[Self.dangling(oldTarget.digest)] == nil)
        #expect(!images.values.contains { $0.digest == replacement.digest })
    }

    @Test("push reconciles a familiar-only owner to the host-qualified canonical key")
    func servicePushReconcilesFamiliarOwner() async throws {
        let familiar = Self.image(
            reference: Self.familiar,
            digestCharacter: "a"
        )
        let store = FakeImageReferenceStore([familiar])
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: store,
            mutationCoordinator: coordinator
        )
        let pusher = RecordingImagePusher()
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store,
            imagePusher: pusher
        )

        let progress = try await service.push(
            reference: Self.familiar,
            platform: Platform(arch: "arm64", os: "linux"),
            logger: Logger(label: "canonical-push-test")
        )
        for try await _ in progress {}

        let images = await store.imagesByReference()
        #expect(images[Self.canonical]?.digest == familiar.digest)
        #expect(images[Self.familiar] == nil)
        #expect(images[Self.dangling(familiar.digest)] == nil)
        #expect(await pusher.references == [Self.canonical])
    }

    @Test("tag normalization returns the surviving exact canonical handle")
    func serviceTagReturnsCommittedCanonicalHandle() async throws {
        let familiar = Self.image(
            reference: Self.familiar,
            digestCharacter: "a"
        )
        let store = FakeImageReferenceStore([familiar])
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: store,
            mutationCoordinator: coordinator
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store
        )

        let result = try await service.tag(
            source: Self.canonical,
            target: Self.canonical
        )

        let images = await store.imagesByReference()
        #expect(result.image.reference == Self.canonical)
        #expect(result.image.digest == familiar.digest)
        #expect(images[Self.canonical]?.digest == familiar.digest)
        #expect(images[Self.familiar] == nil)
    }

    @Test("push passes no platform filter when the image graph includes an artifact")
    func servicePushPreservesArtifactGraph() async throws {
        let owner = Self.image(
            reference: Self.familiar,
            digestCharacter: "a"
        )
        let platform = Platform(arch: "arm64", os: "linux")
        let runnableDigest = "sha256:" + String(repeating: "b", count: 64)
        let artifactDigest = "sha256:" + String(repeating: "c", count: 64)
        let runnableConfig = "sha256:" + String(repeating: "d", count: 64)
        let artifactConfig = "sha256:" + String(repeating: "e", count: 64)
        let runnable = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: runnableDigest,
            size: 100,
            platform: platform
        )
        let artifact = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: artifactDigest,
            size: 80,
            platform: platform,
            artifactType: "application/vnd.example.provenance"
        )
        let selector = RunnableImageSelector(
            contentProvider: ArtifactPushContentProvider(
                index: Index(manifests: [artifact, runnable]),
                manifests: [
                    runnableDigest: Manifest(
                        config: Descriptor(
                            mediaType: MediaTypes.imageConfig,
                            digest: runnableConfig,
                            size: 20
                        ),
                        layers: []
                    ),
                    artifactDigest: Manifest(
                        config: Descriptor(
                            mediaType: MediaTypes.imageConfig,
                            digest: artifactConfig,
                            size: 20
                        ),
                        layers: [],
                        subject: runnable,
                        artifactType: "application/vnd.example.provenance"
                    ),
                ],
                configs: [
                    runnableConfig: ContainerizationOCI.Image(
                        architecture: "arm64",
                        os: "linux",
                        rootfs: Rootfs(type: "layers", diffIDs: [])
                    ),
                    artifactConfig: ContainerizationOCI.Image(
                        architecture: "unknown",
                        os: "unknown",
                        rootfs: Rootfs(type: "layers", diffIDs: [])
                    ),
                ]
            )
        )
        let store = FakeImageReferenceStore([owner])
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: store,
            mutationCoordinator: coordinator
        )
        let pusher = RecordingImagePusher()
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store,
            imagePusher: pusher,
            runnableImageSelector: selector
        )

        let progress = try await service.push(
            reference: Self.familiar,
            platform: nil,
            logger: Logger(label: "artifact-graph-push-test")
        )
        for try await _ in progress {}

        #expect(await pusher.references == [Self.canonical])
        let pushedPlatforms = await pusher.platforms
        #expect(pushedPlatforms.count == 1)
        #expect(pushedPlatforms[0] == nil)
    }

    @Test("deleting an exact canonical owner by digest retires a stale familiar claimant")
    func serviceDigestDeletePreventsTagResurrection() async throws {
        let stale = Self.image(
            reference: Self.familiar,
            digestCharacter: "a"
        )
        let owner = Self.image(
            reference: Self.canonical,
            digestCharacter: "b"
        )
        let manifestDigest = "sha256:" + String(repeating: "c", count: 64)
        let configDigest = "sha256:" + String(repeating: "d", count: 64)
        let ownerIndex = Index(
            manifests: [
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: manifestDigest,
                    size: 100,
                    platform: Platform(arch: "arm64", os: "linux")
                )
            ]
        )
        let ownerManifest = Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: configDigest,
                size: 20
            ),
            layers: []
        )
        let store = FakeImageReferenceStore([stale, owner])
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: StaticImageIdentityCatalog(
                [stale, owner],
                indexes: [owner.digest: ownerIndex],
                manifests: [manifestDigest: ownerManifest]
            ),
            mutationCoordinator: coordinator
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store,
            containerInventoryProvider: EmptyContainerSnapshotInventoryProvider()
        )

        let result = try await service.delete(id: configDigest, force: false)

        let images = await store.imagesByReference()
        #expect(images[Self.canonical] == nil)
        #expect(images[Self.familiar] == nil)
        #expect(images[Self.dangling(stale.digest)]?.digest == stale.digest)
        #expect(!images.values.contains { $0.digest == owner.digest })
        #expect(result.untaggedReferences == [Self.canonical])
        #expect(result.deletedDigest == configDigest)
    }

    @Test("a hidden preservation key is not a second Docker tag during digest deletion")
    func serviceDigestDeleteIgnoresHiddenReferenceForConflict() async throws {
        let owner = Self.image(
            reference: Self.canonical,
            digestCharacter: "b"
        )
        let marker = Self.image(
            reference: Self.dangling(owner.digest),
            digestCharacter: "b"
        )
        let store = FakeImageReferenceStore([owner, marker])
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: StaticImageIdentityCatalog([owner, marker]),
            mutationCoordinator: coordinator
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store,
            containerInventoryProvider: EmptyContainerSnapshotInventoryProvider()
        )

        let result = try await service.delete(id: owner.digest, force: false)

        #expect(await store.imagesByReference().isEmpty)
        #expect(result.untaggedReferences == [Self.canonical])
        #expect(result.deletedDigest == result.digest)
        #expect(result.deletedDigest != owner.digest)
    }

    @Test("a shared config ID removes every owning root without becoming ambiguous")
    func serviceDeletesEverySharedConfigOwner() async throws {
        let first = Self.image(
            reference: Self.canonical,
            digestCharacter: "4"
        )
        let second = Self.image(
            reference: "docker.io/library/other:latest",
            digestCharacter: "5"
        )
        let firstManifest = "sha256:" + String(repeating: "6", count: 64)
        let secondManifest = "sha256:" + String(repeating: "7", count: 64)
        let sharedConfig = "sha256:" + String(repeating: "8", count: 64)
        let platform = Platform(arch: "arm64", os: "linux")
        let indexes = [
            first.digest: Index(manifests: [
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: firstManifest,
                    size: 10,
                    platform: platform
                )
            ]),
            second.digest: Index(manifests: [
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: secondManifest,
                    size: 10,
                    platform: platform
                )
            ]),
        ]
        let manifests = [
            firstManifest: Manifest(
                config: Descriptor(
                    mediaType: MediaTypes.imageConfig,
                    digest: sharedConfig,
                    size: 1
                ),
                layers: []
            ),
            secondManifest: Manifest(
                config: Descriptor(
                    mediaType: MediaTypes.imageConfig,
                    digest: sharedConfig,
                    size: 1
                ),
                layers: []
            ),
        ]
        let store = FakeImageReferenceStore([first, second])
        let coordinator = ImageMutationCoordinator()
        let reservations = ContainerImageLeaseReservationRegistry()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: StaticImageIdentityCatalog(
                [first, second],
                indexes: indexes,
                manifests: manifests
            ),
            mutationCoordinator: coordinator
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store,
            containerInventoryProvider: EmptyContainerSnapshotInventoryProvider(),
            imageLeaseReservations: reservations
        )

        let reservation = await reservations.reserve(
            ContainerImageLease(
                image: Self.image(
                    reference: ContainerImageLease.reference(
                        for: second.digest
                    ),
                    digestCharacter: "5"
                )
            )
        )
        do {
            _ = try await service.delete(id: sharedConfig, force: true)
            Issue.record("secondary-root create reservation must block deletion")
        } catch ClientImageError.conflict(let message) {
            #expect(message.contains("cannot be forced"))
        }
        #expect(await store.imagesByReference().count == 2)
        await reservations.release(reservation)

        let result = try await service.delete(
            id: sharedConfig,
            force: true
        )

        #expect(await store.imagesByReference().isEmpty)
        #expect(result.digest == sharedConfig)
        #expect(result.deletedDigest == sharedConfig)
        #expect(
            Set(result.untaggedReferences) == [
                Self.canonical,
                "docker.io/library/other:latest",
            ]
        )
    }

    @Test("deleting a physical repository digest retains a sibling tag")
    func serviceRepositoryDigestDeleteRetainsTag() async throws {
        let owner = Self.image(
            reference: Self.canonical,
            digestCharacter: "b"
        )
        let manifestDigest = "sha256:" + String(repeating: "c", count: 64)
        let configDigest = "sha256:" + String(repeating: "d", count: 64)
        let repositoryDigest = "docker.io/library/example@\(manifestDigest)"
        let digestOwner = Self.image(
            reference: repositoryDigest,
            digestCharacter: "b"
        )
        let index = Index(
            manifests: [
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: manifestDigest,
                    size: 100,
                    platform: Platform(arch: "arm64", os: "linux")
                )
            ]
        )
        let manifest = Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: configDigest,
                size: 20
            ),
            layers: []
        )
        let store = FakeImageReferenceStore([owner, digestOwner])
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: StaticImageIdentityCatalog(
                [owner, digestOwner],
                indexes: [owner.digest: index],
                manifests: [manifestDigest: manifest]
            ),
            mutationCoordinator: coordinator
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store,
            containerInventoryProvider: EmptyContainerSnapshotInventoryProvider()
        )

        let result = try await service.delete(
            id: repositoryDigest,
            force: false
        )

        let images = await store.imagesByReference()
        #expect(images[Self.canonical]?.digest == owner.digest)
        #expect(images[repositoryDigest] == nil)
        #expect(result.untaggedReferences == [repositoryDigest])
        #expect(result.deletedDigest == nil)
    }

    @Test("a post-commit list failure does not turn deletion into an API failure")
    func serviceDeleteToleratesPostCommitObservationFailure() async throws {
        let owner = Self.image(
            reference: Self.canonical,
            digestCharacter: "b"
        )
        let store = FakeImageReferenceStore([owner])
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: StaticImageIdentityCatalog([owner]),
            mutationCoordinator: coordinator
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store,
            containerInventoryProvider: EmptyContainerSnapshotInventoryProvider()
        )
        await store.failFirstListAfterDelete()

        let result = try await service.delete(id: Self.canonical, force: false)

        #expect(await store.imagesByReference().isEmpty)
        #expect(result.untaggedReferences == [Self.canonical])
        #expect(result.deletedDigest == nil)
    }

    private static func manager(
        store: FakeImageReferenceStore
    ) -> CanonicalImageReferenceManager {
        CanonicalImageReferenceManager(
            systemConfig: ContainerSystemConfig(),
            store: store
        )
    }

    private static func image(
        reference: String,
        digestCharacter: Character,
        annotatedName: String? = nil
    ) -> ClientImage {
        ClientImage(
            description: ImageDescription(
                reference: reference,
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: "sha256:" + String(repeating: String(digestCharacter), count: 64),
                    size: 100,
                    annotations: annotatedName.map {
                        [AnnotationKeys.containerizationImageName: $0]
                    }
                )
            )
        )
    }

    private static func dangling(_ digest: String) -> String {
        "moby-dangling@\(digest)"
    }
}

@Suite("Image mutation coordinator")
struct ImageMutationCoordinatorTests {
    @Test("concurrent mutations are serialized across suspension points")
    func mutationsAreSerialized() async throws {
        let coordinator = ImageMutationCoordinator()
        let probe = MutationProbe()
        let firstEntered = AsyncStream<Void>.makeStream()
        let releaseFirst = AsyncStream<Void>.makeStream()

        let first = Task {
            try await coordinator.performMutation {
                await probe.enter("first")
                firstEntered.continuation.yield(())
                for await _ in releaseFirst.stream { break }
                await probe.leave("first")
            }
        }
        var firstEnteredIterator = firstEntered.stream.makeAsyncIterator()
        _ = await firstEnteredIterator.next()

        let second = Task {
            try await coordinator.performMutation {
                await probe.enter("second")
                await probe.leave("second")
            }
        }

        releaseFirst.continuation.yield(())
        releaseFirst.continuation.finish()
        try await first.value
        try await second.value

        let snapshot = await probe.snapshot()
        #expect(snapshot.maximumActive == 1)
        #expect(snapshot.events == ["first-start", "first-end", "second-start", "second-end"])
    }

    @Test("cancelling a lock holder releases admission for the next writer")
    func cancelledHolderReleasesAdmission() async throws {
        let coordinator = ImageMutationCoordinator()
        let holderEntered = AsyncStream<Void>.makeStream()

        let holder = Task {
            try await coordinator.performMutation {
                holderEntered.continuation.yield(())
                try await Task.sleep(for: .seconds(600))
            }
        }
        var holderEnteredIterator = holderEntered.stream.makeAsyncIterator()
        _ = await holderEnteredIterator.next()

        holder.cancel()
        await #expect(throws: CancellationError.self) {
            try await holder.value
        }

        let nextResult = try await coordinator.performMutation { 42 }
        #expect(nextResult == 42)
    }

    @Test("a cancelled queued writer never runs its body or blocks a later writer")
    func cancelledQueuedWriterDoesNotRunOrBlock() async throws {
        let coordinator = ImageMutationCoordinator()
        let probe = CancelledWorkProbe()
        let holderEntered = AsyncStream<Void>.makeStream()
        let releaseHolder = AsyncStream<Void>.makeStream()

        let holder = Task {
            try await coordinator.performMutation {
                holderEntered.continuation.yield(())
                for await _ in releaseHolder.stream { break }
            }
        }
        var holderEnteredIterator = holderEntered.stream.makeAsyncIterator()
        _ = await holderEnteredIterator.next()

        let cancelledWriter = Task {
            try await coordinator.performMutation {
                await probe.markOperationRan()
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        cancelledWriter.cancel()

        let nextWriter = Task {
            try await coordinator.performMutation { 42 }
        }
        try? await Task.sleep(for: .milliseconds(20))

        releaseHolder.continuation.yield(())
        releaseHolder.continuation.finish()
        try await holder.value

        await #expect(throws: CancellationError.self) {
            try await cancelledWriter.value
        }
        #expect(await probe.operationRan == false)
        #expect(try await nextWriter.value == 42)
    }

    @Test("cancelling push during its readiness wait cancels queued push work")
    func cancelledPushReadinessDoesNotLeakQueuedWork() async throws {
        let coordinator = ImageMutationCoordinator()
        let catalog = PushWorkProbeCatalog()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: catalog,
            mutationCoordinator: coordinator
        )
        let service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: FakeImageReferenceStore([])
        )
        let holderEntered = AsyncStream<Void>.makeStream()
        let releaseHolder = AsyncStream<Void>.makeStream()

        let holder = Task {
            try await coordinator.performMutation {
                holderEntered.continuation.yield(())
                for await _ in releaseHolder.stream { break }
            }
        }
        var holderEnteredIterator = holderEntered.stream.makeAsyncIterator()
        _ = await holderEnteredIterator.next()

        let push = Task {
            try await service.push(
                reference: "docker.io/library/cancelled-push:latest",
                platform: nil,
                logger: Logger(label: "cancelled-push-test")
            )
        }
        try? await Task.sleep(for: .milliseconds(20))
        push.cancel()

        let nextWriter = Task {
            try await coordinator.performMutation { 42 }
        }
        try? await Task.sleep(for: .milliseconds(20))

        releaseHolder.continuation.yield(())
        releaseHolder.continuation.finish()
        try await holder.value

        await #expect(throws: CancellationError.self) {
            try await push.value
        }
        #expect(try await nextWriter.value == 42)
        #expect(
            await catalog.listCallCount == 0,
            "the cancelled push must never begin image resolution after writer admission"
        )
    }

    @Test("a stable read retries when a mutation overlaps its first attempt")
    func stableReadRetriesAfterMutation() async throws {
        let coordinator = ImageMutationCoordinator()
        let probe = StableReadProbe()
        let firstReadEntered = AsyncStream<Void>.makeStream()
        let releaseFirstRead = AsyncStream<Void>.makeStream()

        let reader = Task {
            try await coordinator.stableRead {
                let attempt = await probe.beginRead()
                let snapshot = await probe.value()
                if attempt == 1 {
                    firstReadEntered.continuation.yield(())
                    for await _ in releaseFirstRead.stream { break }
                }
                return snapshot
            }
        }
        var firstReadIterator = firstReadEntered.stream.makeAsyncIterator()
        _ = await firstReadIterator.next()

        try await coordinator.performMutation {
            await probe.setValue(1)
        }
        releaseFirstRead.continuation.yield(())
        releaseFirstRead.continuation.finish()

        #expect(try await reader.value == 1)
        #expect(await probe.readAttempts() == 2)
    }

    @Test("cancelling a stable reader waiting behind a mutation is prompt and runs no read")
    func cancelledStableReaderIsPrompt() async throws {
        let coordinator = ImageMutationCoordinator()
        let probe = CancelledWorkProbe()
        let holderEntered = AsyncStream<Void>.makeStream()
        let releaseHolder = AsyncStream<Void>.makeStream()

        let holder = Task {
            try await coordinator.performMutation {
                holderEntered.continuation.yield(())
                for await _ in releaseHolder.stream { break }
            }
        }
        var holderEnteredIterator = holderEntered.stream.makeAsyncIterator()
        _ = await holderEnteredIterator.next()

        let reader = Task {
            do {
                return try await coordinator.stableRead {
                    await probe.markOperationRan()
                    return 1
                }
            } catch is CancellationError {
                await probe.markCancellationObserved()
                throw CancellationError()
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        reader.cancel()

        for _ in 0..<50 {
            if await probe.cancellationObserved { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let cancelledWhileMutationWasHeld = await probe.cancellationObserved

        releaseHolder.continuation.yield(())
        releaseHolder.continuation.finish()
        try await holder.value

        await #expect(throws: CancellationError.self) {
            try await reader.value
        }
        #expect(
            cancelledWhileMutationWasHeld,
            "reader cancellation must not wait for the active mutation to finish"
        )
        #expect(await probe.operationRan == false)
    }
}

private enum FakeStoreError: Error, Equatable {
    case injected
}

/// Resolver-backed service tests need a real runnable OCI graph. Empty indexes
/// would model an artifact/corrupt root and production correctly rejects those
/// as non-runnable, masking the reference-mutation behavior under test.
private enum RunnableCatalogFixture {
    static func manifestDigest(for rootDigest: String) -> String {
        "sha256:"
            + Data("\(rootDigest)\u{0}manifest".utf8).sha256Hex()
    }

    static func configDigest(for rootDigest: String) -> String {
        "sha256:"
            + Data("\(rootDigest)\u{0}config".utf8).sha256Hex()
    }

    static func index(for rootDigest: String) -> Index {
        Index(
            manifests: [
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: manifestDigest(for: rootDigest),
                    size: 100,
                    platform: Platform(arch: "arm64", os: "linux")
                )
            ]
        )
    }

    static func manifest(
        digest: String,
        rootDigests: [String]
    ) -> Manifest? {
        guard
            let rootDigest = rootDigests.first(where: {
                manifestDigest(for: $0) == digest
            })
        else {
            return nil
        }
        return Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: configDigest(for: rootDigest),
                size: 20
            ),
            layers: []
        )
    }
}

private actor StaticImageIdentityCatalog: ImageIdentityCatalog {
    private let images: [ClientImage]
    private let indexes: [String: Index]
    private let manifests: [String: Manifest]

    init(
        _ images: [ClientImage],
        indexes: [String: Index] = [:],
        manifests: [String: Manifest] = [:]
    ) {
        self.images = images
        self.indexes = indexes
        self.manifests = manifests
    }

    func list() async throws -> [ClientImage] {
        images
    }

    func index(for image: ClientImage) async throws -> Index {
        indexes[image.digest]
            ?? RunnableCatalogFixture.index(for: image.digest)
    }

    func index(digest: String) async throws -> Index? {
        indexes[digest]
    }

    func manifest(digest: String) async throws -> Manifest? {
        manifests[digest]
            ?? RunnableCatalogFixture.manifest(
                digest: digest,
                rootDigests: images.map(\.digest)
            )
    }
}

private struct FakeImagePuller: ImagePulling {
    let image: ClientImage
    let store: FakeImageReferenceStore
    var distributionDigest: String? = nil

    func pullAndUnpack(
        reference: String,
        platform: Platform,
        containerSystemConfig: ContainerSystemConfig,
        downloadProgress: ProgressUpdateHandler?,
        unpackProgress: ProgressUpdateHandler?
    ) async throws -> PulledImageResult {
        let pulled = ClientImage(
            description: ImageDescription(
                reference: reference,
                descriptor: image.descriptor
            )
        )
        await store.put(pulled)
        return PulledImageResult(
            image: pulled,
            distributionDigest: distributionDigest ?? pulled.digest
        )
    }
}

private struct OverwriteThenFailImagePuller: ImagePulling {
    let image: ClientImage
    let store: FakeImageReferenceStore

    func pullAndUnpack(
        reference: String,
        platform: Platform,
        containerSystemConfig: ContainerSystemConfig,
        downloadProgress: ProgressUpdateHandler?,
        unpackProgress: ProgressUpdateHandler?
    ) async throws -> PulledImageResult {
        let pulled = ClientImage(
            description: ImageDescription(
                reference: reference,
                descriptor: image.descriptor
            )
        )
        await store.put(pulled)
        throw FakeStoreError.injected
    }
}

private actor PlatformFallbackImagePuller: ImagePulling {
    let image: ClientImage
    let store: FakeImageReferenceStore
    private(set) var requestedArchitectures: [String] = []

    init(image: ClientImage, store: FakeImageReferenceStore) {
        self.image = image
        self.store = store
    }

    func pullAndUnpack(
        reference: String,
        platform: Platform,
        containerSystemConfig: ContainerSystemConfig,
        downloadProgress: ProgressUpdateHandler?,
        unpackProgress: ProgressUpdateHandler?
    ) async throws -> PulledImageResult {
        requestedArchitectures.append(platform.architecture)
        guard platform.architecture == "amd64" else {
            throw ContainerizationError(
                .unsupported,
                message: "image does not support required platforms"
            )
        }
        let pulled = ClientImage(
            description: ImageDescription(
                reference: reference,
                descriptor: image.descriptor
            )
        )
        await store.put(pulled)
        return PulledImageResult(
            image: pulled,
            distributionDigest: pulled.digest
        )
    }
}

private struct CancellationIgnoringImagePuller: ImagePulling {
    let image: ClientImage
    let store: FakeImageReferenceStore
    let replacementWritten: AsyncStream<Void>.Continuation
    let cancellationObserved: AsyncStream<Void>.Continuation

    func pullAndUnpack(
        reference: String,
        platform: Platform,
        containerSystemConfig: ContainerSystemConfig,
        downloadProgress: ProgressUpdateHandler?,
        unpackProgress: ProgressUpdateHandler?
    ) async throws -> PulledImageResult {
        let pulled = ClientImage(
            description: ImageDescription(
                reference: reference,
                descriptor: image.descriptor
            )
        )
        await store.put(pulled)
        replacementWritten.yield(())
        while !Task.isCancelled {
            await Task.yield()
        }
        cancellationObserved.yield(())
        return PulledImageResult(
            image: pulled,
            distributionDigest: pulled.digest
        )
    }
}

private actor DuplicateImageReferenceStore: ImageReferenceStore {
    private var images: [ClientImage]

    init(_ images: [ClientImage]) {
        self.images = images
    }

    func list() async throws -> [ClientImage] {
        images
    }

    func tag(existing: String, new: String) async throws -> ClientImage {
        guard let source = images.first(where: { $0.reference == existing }) else {
            throw ContainerizationError(.notFound, message: "image \(existing) not found")
        }
        let tagged = ClientImage(
            description: ImageDescription(
                reference: new,
                descriptor: source.descriptor
            )
        )
        images.append(tagged)
        return tagged
    }

    func delete(reference: String) async throws {
        images.removeAll { $0.reference == reference }
    }

    func cleanUpOrphanedBlobs() async throws -> UInt64 {
        0
    }
}

private actor FakeImageReferenceStore: ImageReferenceStore, ImageIdentityCatalog {
    private var images: [String: ClientImage]
    private let cancellationAwareOperations: Bool
    private var failingDeletes: Set<String> = []
    private var cancellingTags: Set<String> = []
    private var commitThenFailTags: Set<String> = []
    private var failListAfterDelete = false
    private var pendingListFailure = false

    init(
        _ images: [ClientImage],
        cancellationAwareOperations: Bool = false
    ) {
        self.images = Dictionary(uniqueKeysWithValues: images.map { ($0.reference, $0) })
        self.cancellationAwareOperations = cancellationAwareOperations
    }

    func list() async throws -> [ClientImage] {
        if cancellationAwareOperations { try Task.checkCancellation() }
        if pendingListFailure {
            pendingListFailure = false
            throw FakeStoreError.injected
        }
        return Array(images.values)
    }

    func tag(existing: String, new: String) async throws -> ClientImage {
        if cancellationAwareOperations { try Task.checkCancellation() }
        if cancellingTags.remove(new) != nil {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            throw CancellationError()
        }
        guard let existingImage = images[existing] else {
            throw ContainerizationError(.notFound, message: "image \(existing) not found")
        }
        let tagged = ClientImage(
            description: ImageDescription(
                reference: new,
                descriptor: existingImage.descriptor
            )
        )
        images[new] = tagged
        if commitThenFailTags.remove(new) != nil {
            throw FakeStoreError.injected
        }
        return tagged
    }

    func delete(reference: String) async throws {
        if cancellationAwareOperations { try Task.checkCancellation() }
        if failingDeletes.remove(reference) != nil {
            throw FakeStoreError.injected
        }
        images.removeValue(forKey: reference)
        if failListAfterDelete {
            failListAfterDelete = false
            pendingListFailure = true
        }
    }

    func cleanUpOrphanedBlobs() async throws -> UInt64 {
        0
    }

    func index(for image: ClientImage) async throws -> Index {
        RunnableCatalogFixture.index(for: image.digest)
    }

    func manifest(digest: String) async throws -> Manifest? {
        RunnableCatalogFixture.manifest(
            digest: digest,
            rootDigests: images.values.map(\.digest)
        )
    }

    func failNextDelete(reference: String) {
        failingDeletes.insert(reference)
    }

    func cancelNextTag(new: String) {
        cancellingTags.insert(new)
    }

    func commitThenFailNextTag(new: String) {
        commitThenFailTags.insert(new)
    }

    func failFirstListAfterDelete() {
        failListAfterDelete = true
    }

    func put(_ image: ClientImage) {
        images[image.reference] = image
    }

    func image(reference: String) -> ClientImage? {
        images[reference]
    }

    func imagesByReference() -> [String: ClientImage] {
        images
    }
}

private actor RecordingImagePusher: ImagePushing {
    private(set) var references: [String] = []
    private(set) var platforms: [Platform?] = []

    func push(
        image: ClientImage,
        platform: Platform?,
        scheme: RequestScheme,
        containerSystemConfig: ContainerSystemConfig,
        progressUpdate: ProgressUpdateHandler?
    ) async throws {
        references.append(image.reference)
        platforms.append(platform)
    }
}

private struct ArtifactPushContentProvider: RunnableImageContentProviding {
    let index: Index
    let manifests: [String: Manifest]
    let configs: [String: ContainerizationOCI.Image]

    func index(for image: ClientImage) async throws -> Index {
        index
    }

    func manifest(digest: String) async throws -> Manifest? {
        manifests[digest]
    }

    func config(digest: String) async throws -> ContainerizationOCI.Image? {
        configs[digest]
    }
}

private actor MutationProbe {
    private var active = 0
    private var maximumActive = 0
    private var events: [String] = []

    func enter(_ name: String) {
        active += 1
        maximumActive = max(maximumActive, active)
        events.append("\(name)-start")
    }

    func leave(_ name: String) {
        events.append("\(name)-end")
        active -= 1
    }

    func snapshot() -> (maximumActive: Int, events: [String]) {
        (maximumActive, events)
    }
}

private actor StableReadProbe {
    private var storedValue = 0
    private var attempts = 0

    func beginRead() -> Int {
        attempts += 1
        return attempts
    }

    func setValue(_ value: Int) {
        storedValue = value
    }

    func value() -> Int {
        storedValue
    }

    func readAttempts() -> Int {
        attempts
    }
}

private actor CancelledWorkProbe {
    private(set) var operationRan = false
    private(set) var cancellationObserved = false

    func markOperationRan() {
        operationRan = true
    }

    func markCancellationObserved() {
        cancellationObserved = true
    }
}

private actor PushWorkProbeCatalog: ImageIdentityCatalog {
    private(set) var listCallCount = 0

    func list() async throws -> [ClientImage] {
        listCallCount += 1
        return []
    }

    func index(for image: ClientImage) async throws -> Index {
        Index(manifests: [])
    }

    func manifest(digest: String) async throws -> Manifest? {
        nil
    }
}

private struct EmptyContainerSnapshotInventoryProvider:
    ContainerSnapshotInventoryProviding
{
    func containers() async throws -> [ContainerSnapshot] {
        []
    }
}
