import ContainerAPIClient
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Testing

@testable import socktainer

@Suite("Container runtime image lease reconciliation")
struct ContainerImageLeaseReconcilerTests {
    @Test("lease acquire, verify, and release ignore non-identity descriptor metadata")
    func leaseLifecycleUsesImmutableRootDigest() async throws {
        let digest = LeaseReconcilerFixture.rootDescriptor.digest
        let leaseReference = ContainerImageLease.reference(for: digest)
        let oldDescriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: digest,
            size: 256,
            annotations: ["org.opencontainers.image.ref.name": "old:latest"]
        )
        let newDescriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: digest,
            size: 256,
            annotations: ["org.opencontainers.image.ref.name": "new:latest"]
        )
        let existingLease = Self.image(
            reference: leaseReference,
            descriptor: oldDescriptor
        )
        let newSource = Self.image(
            reference: "docker.io/library/example:latest",
            descriptor: newDescriptor
        )
        let store = MetadataLeaseStore([existingLease, newSource])
        let manager = LiveContainerImageLeaseManager(store: store)

        let acquired = try await manager.acquire(
            for: Self.resolved(newSource)
        )
        #expect(acquired.image.descriptor == oldDescriptor)

        // A later same-content import can rewrite reference annotations while
        // stopped containers still retain the older lease object.
        await store.put(
            Self.image(
                reference: leaseReference,
                descriptor: newDescriptor
            )
        )
        try await manager.verify(acquired)
        try await manager.release(acquired)
        #expect(await store.image(reference: leaseReference) == nil)
    }

    @Test("lease creation accepts a same-digest source with different annotations")
    func leaseCreationFindsSameDigestSource() async throws {
        let digest = LeaseReconcilerFixture.rootDescriptor.digest
        let resolvedDescriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: digest,
            size: 256,
            annotations: ["org.opencontainers.image.ref.name": "resolved:latest"]
        )
        let storedDescriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: digest,
            size: 256,
            annotations: ["org.opencontainers.image.ref.name": "stored:latest"]
        )
        let resolvedImage = Self.image(
            reference: "docker.io/library/example:latest",
            descriptor: resolvedDescriptor
        )
        let storedImage = Self.image(
            reference: resolvedImage.reference,
            descriptor: storedDescriptor
        )
        let store = MetadataLeaseStore([storedImage])

        let acquired = try await LiveContainerImageLeaseManager(store: store)
            .acquire(for: Self.resolved(resolvedImage))

        #expect(acquired.rootDigest == digest)
        #expect(
            acquired.reference == ContainerImageLease.reference(for: digest)
        )
        #expect(acquired.image.descriptor == storedDescriptor)
    }

    @Test("lease survives until the final container sharing its immutable root is deleted")
    func sharedRootLifetime() async throws {
        let fixture = LeaseReconcilerFixture(containerIDs: ["first", "second"])

        await fixture.reconciler.reconcile(rootDescriptor: fixture.descriptor)
        #expect(await fixture.store.hasLease)

        await fixture.inventory.set([
            LeaseReconcilerFixture.container(
                id: "second",
                descriptor: fixture.descriptor
            )
        ])
        await fixture.reconciler.reconcile(rootDescriptor: fixture.descriptor)
        #expect(await fixture.store.hasLease)

        await fixture.inventory.set([])
        await fixture.reconciler.reconcile(rootDescriptor: fixture.descriptor)
        #expect(!(await fixture.store.hasLease))
        #expect(await fixture.store.deleteCount == 1)
    }

    @Test("in-flight create reservation prevents orphan reconciliation and is released atomically")
    func createReservationClosesInventoryGap() async throws {
        let fixture = LeaseReconcilerFixture(containerIDs: [])
        let reservation = await fixture.reservations.reserve(fixture.lease)

        await fixture.reconciler.reconcile(rootDescriptor: fixture.descriptor)
        #expect(await fixture.store.hasLease)
        #expect(
            await fixture.reservations.isReserved(
                rootDigest: fixture.descriptor.digest
            )
        )

        await fixture.reconciler.reconcile(
            rootDescriptor: fixture.descriptor,
            releasing: reservation
        )
        #expect(!(await fixture.store.hasLease))
        #expect(
            !(await fixture.reservations.isReserved(
                rootDigest: fixture.descriptor.digest
            ))
        )
    }

    @Test("concurrent reconciliation releases an exact lease once")
    func concurrentReconciliationIsIdempotent() async throws {
        let fixture = LeaseReconcilerFixture(containerIDs: [])

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await fixture.reconciler.reconcile(
                        rootDescriptor: fixture.descriptor
                    )
                }
            }
        }

        #expect(!(await fixture.store.hasLease))
        #expect(await fixture.store.deleteCount == 1)
    }

    @Test("auto-remove cleanup reconciles the immutable root after Apple reaps the container")
    func autoRemoveReconcilesFallbackRoot() async throws {
        let recorder = RecordingLeaseReconciler()
        let descriptor = LeaseReconcilerFixture.rootDescriptor

        await ContainerAutoRemoveCleanup.perform(
            hexId: "auto-remove-hex-lease-test",
            nativeId: "auto-remove-native-lease-test",
            fallbackImage: "example:latest",
            fallbackLabels: [:],
            dnsServer: nil,
            broadcaster: nil,
            fallbackRootDescriptor: descriptor,
            leaseReconciler: recorder
        )

        #expect(await recorder.digests == [descriptor.digest])
    }

    private static func image(
        reference: String,
        descriptor: Descriptor
    ) -> ClientImage {
        ClientImage(
            description: ImageDescription(
                reference: reference,
                descriptor: descriptor
            )
        )
    }

    private static func resolved(_ image: ClientImage) -> ResolvedImageIdentity {
        ResolvedImageIdentity(
            image: image,
            reference: image.reference,
            references: [image.reference],
            storeReferences: [image.reference],
            repositoryDigests: [],
            selectedStoreReference: image.reference,
            kind: .reference,
            variantConstraint: .unconstrained
        )
    }
}

private struct LeaseReconcilerFixture: Sendable {
    static let rootDescriptor = Descriptor(
        mediaType: MediaTypes.index,
        digest: "sha256:" + String(repeating: "8", count: 64),
        size: 256
    )

    let descriptor = Self.rootDescriptor
    let lease: ContainerImageLease
    let store: LifecycleLeaseStore
    let inventory: MutableLeaseContainerInventory
    let reservations: ContainerImageLeaseReservationRegistry
    let reconciler: LiveContainerImageLeaseReconciler

    init(containerIDs: [String]) {
        let leaseImage = ClientImage(
            description: ImageDescription(
                reference: ContainerImageLease.reference(
                    for: Self.rootDescriptor.digest
                ),
                descriptor: Self.rootDescriptor
            )
        )
        let store = LifecycleLeaseStore(image: leaseImage)
        let inventory = MutableLeaseContainerInventory(
            containerIDs.map {
                Self.container(id: $0, descriptor: Self.rootDescriptor)
            }
        )
        let reservations = ContainerImageLeaseReservationRegistry()

        self.lease = ContainerImageLease(image: leaseImage)
        self.store = store
        self.inventory = inventory
        self.reservations = reservations
        self.reconciler = LiveContainerImageLeaseReconciler(
            mutationCoordinator: ImageMutationCoordinator(),
            containerInventoryProvider: inventory,
            leaseManager: LiveContainerImageLeaseManager(store: store),
            referenceStore: store,
            reservationRegistry: reservations
        )
    }

    static func container(
        id: String,
        descriptor: Descriptor
    ) -> ContainerSnapshot {
        ContainerSnapshot(
            configuration: ContainerConfiguration(
                id: id,
                image: ImageDescription(
                    reference: ContainerImageLease.reference(
                        for: descriptor.digest
                    ),
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
    }
}

private actor MutableLeaseContainerInventory:
    ContainerSnapshotInventoryProviding
{
    private var snapshots: [ContainerSnapshot]

    init(_ snapshots: [ContainerSnapshot]) {
        self.snapshots = snapshots
    }

    func containers() async throws -> [ContainerSnapshot] {
        snapshots
    }

    func set(_ snapshots: [ContainerSnapshot]) {
        self.snapshots = snapshots
    }
}

private actor LifecycleLeaseStore: ImageReferenceStore {
    private var image: ClientImage?
    private(set) var deleteCount = 0

    init(image: ClientImage) {
        self.image = image
    }

    var hasLease: Bool { image != nil }

    func list() async throws -> [ClientImage] {
        image.map { [$0] } ?? []
    }

    func tag(existing: String, new: String) async throws -> ClientImage {
        guard let image, image.reference == existing else {
            throw ContainerizationError(
                .notFound,
                message: "image \(existing) not found"
            )
        }
        let tagged = ClientImage(
            description: ImageDescription(
                reference: new,
                descriptor: image.descriptor
            )
        )
        self.image = tagged
        return tagged
    }

    func delete(reference: String) async throws {
        guard image?.reference == reference else { return }
        image = nil
        deleteCount += 1
    }

    func cleanUpOrphanedBlobs() async throws -> UInt64 { 0 }
}

private actor MetadataLeaseStore: ImageReferenceStore {
    private var images: [String: ClientImage]

    init(_ images: [ClientImage]) {
        self.images = Dictionary(
            uniqueKeysWithValues: images.map { ($0.reference, $0) }
        )
    }

    func list() async throws -> [ClientImage] {
        Array(images.values)
    }

    func tag(existing: String, new: String) async throws -> ClientImage {
        guard let source = images[existing] else {
            throw ContainerizationError(
                .notFound,
                message: "image \(existing) not found"
            )
        }
        let tagged = ClientImage(
            description: ImageDescription(
                reference: new,
                descriptor: source.descriptor
            )
        )
        images[new] = tagged
        return tagged
    }

    func delete(reference: String) async throws {
        images.removeValue(forKey: reference)
    }

    func cleanUpOrphanedBlobs() async throws -> UInt64 { 0 }

    func put(_ image: ClientImage) {
        images[image.reference] = image
    }

    func image(reference: String) -> ClientImage? {
        images[reference]
    }
}

private actor RecordingLeaseReconciler: ContainerImageLeaseReconciling {
    private(set) var digests: [String] = []

    func reconcile(
        rootDescriptor: Descriptor,
        releasing reservation: ContainerImageLeaseReservation?
    ) async {
        digests.append(rootDescriptor.digest)
    }
}
