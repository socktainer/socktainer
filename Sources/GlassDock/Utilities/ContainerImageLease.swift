import ContainerAPIClient
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging

/// Read boundary for immutable image roots retained by both running and stopped
/// containers. Image deletion, prune, and lease reconciliation share this
/// attribution so no path garbage-collects a root needed by a later restart.
protocol ContainerSnapshotInventoryProviding: Sendable {
    func containers() async throws -> [ContainerSnapshot]
}

struct LiveContainerSnapshotInventoryProvider:
    ContainerSnapshotInventoryProviding
{
    func containers() async throws -> [ContainerSnapshot] {
        try await ContainerClient().list()
    }
}

struct ContainerImageLease: Sendable {
    static let referencePrefix = "glassdock-runtime@sha256:"

    let image: ClientImage

    var reference: String { image.reference }
    var rootDigest: String { image.digest }

    static func reference(for digest: String) -> String {
        "glassdock-runtime@\(digest.hasPrefix("sha256:") ? digest : "sha256:\(digest)")"
    }

    static func isReference(_ reference: String) -> Bool {
        reference.hasPrefix(referencePrefix)
    }
}

/// A counted, process-wide reservation for an image root that is in the
/// container-create pipeline but is not yet visible in Apple's container
/// inventory.
///
/// The reservation is acquired while the image-mutation writer is still held,
/// immediately after the immutable runtime lease is created. Image prune checks
/// this registry while holding that same writer. This closes the otherwise long
/// race between lease acquisition and `ContainerClient.create` without keeping
/// image mutations blocked during kernel, network, volume, and rootfs setup.
struct ContainerImageLeaseReservation: Sendable, Hashable {
    fileprivate let id: UUID
    let leaseReference: String
    let rootDigest: String

    var reservationID: UUID { id }
}

actor ContainerImageLeaseReservationRegistry {
    static let shared = ContainerImageLeaseReservationRegistry()

    private var reservations: [UUID: ContainerImageLeaseReservation] = [:]

    func reserve(_ lease: ContainerImageLease) -> ContainerImageLeaseReservation {
        let reservation = ContainerImageLeaseReservation(
            id: UUID(),
            leaseReference: lease.reference,
            rootDigest: lease.rootDigest
        )
        reservations[reservation.id] = reservation
        return reservation
    }

    /// Idempotent so a success/error convergence path can safely release the
    /// same token after detached reconciliation.
    func release(_ reservation: ContainerImageLeaseReservation) {
        reservations.removeValue(forKey: reservation.id)
    }

    func isReserved(leaseReference: String) -> Bool {
        reservations.values.contains {
            $0.leaseReference == leaseReference
        }
    }

    func isReserved(rootDigest: String) -> Bool {
        reservations.values.contains { $0.rootDigest == rootDigest }
    }

    func isReserved(id: UUID) -> Bool {
        reservations[id] != nil
    }

    func reservedLeaseReferences() -> Set<String> {
        Set(reservations.values.map(\.leaseReference))
    }

    func reservedRootDigests() -> Set<String> {
        Set(reservations.values.map(\.rootDigest))
    }

    #if DEBUG
    func resetForTesting() {
        reservations.removeAll()
    }
    #endif
}

enum ContainerImageLeaseError: Error, Equatable {
    case sourceMissing(reference: String, digest: String)
    case corruptLease(reference: String, expected: String, actual: String)
    case leaseMissing(reference: String, digest: String)
}

protocol ContainerImageLeasing: Sendable {
    func acquire(for resolved: ResolvedImageIdentity) async throws
        -> ContainerImageLease
    func verify(_ lease: ContainerImageLease) async throws
    func release(_ lease: ContainerImageLease) async throws
}

/// Retains the immutable OCI root selected by Docker under a hidden, digest-
/// addressed Apple reference.
///
/// A mutable tag cannot safely be persisted in `ContainerConfiguration.image`:
/// Apple's container service resolves that exact key again and rejects the
/// request if a concurrent build has moved it to another descriptor. The hidden
/// reference is idempotent and content-addressed, so it remains a valid runtime
/// identity after the Docker tag moves. Its dedicated namespace is intentionally
/// distinct from `moby-dangling`: canonical tag replacement is allowed to retire
/// redundant dangling references, but must never retire a live runtime lease.
struct LiveContainerImageLeaseManager: ContainerImageLeasing {
    private let store: any ImageReferenceStore

    init(store: any ImageReferenceStore = LiveImageReferenceStore()) {
        self.store = store
    }

    func acquire(for resolved: ResolvedImageIdentity) async throws
        -> ContainerImageLease
    {
        let expected = resolved.image.descriptor
        let leaseReference = ContainerImageLease.reference(
            for: expected.digest
        )
        let images = try await store.list()

        if let existing = images.first(where: {
            $0.reference == leaseReference
        }) {
            guard existing.digest == expected.digest else {
                throw ContainerImageLeaseError.corruptLease(
                    reference: leaseReference,
                    expected: expected.digest,
                    actual: existing.digest
                )
            }
            return ContainerImageLease(image: existing)
        }

        let preferredSources = [
            resolved.selectedStoreReference,
            resolved.image.reference,
        ]
        .compactMap { $0 }
        let source =
            images
            // Descriptor annotations, URLs, and platform metadata are not part
            // of a content identity and can legitimately differ after another
            // import/tag operation. The hidden key is digest-addressed; select
            // and validate its source by the immutable root digest.
            .filter { $0.digest == expected.digest }
            .sorted { left, right in
                let leftRank =
                    preferredSources.firstIndex(
                        of: left.reference
                    ) ?? Int.max
                let rightRank =
                    preferredSources.firstIndex(
                        of: right.reference
                    ) ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                return left.reference < right.reference
            }
            .first

        guard let source else {
            throw ContainerImageLeaseError.sourceMissing(
                reference: resolved.image.reference,
                digest: expected.digest
            )
        }

        let created = try await store.tag(
            existing: source.reference,
            new: leaseReference
        )
        guard created.reference == leaseReference,
            created.digest == expected.digest
        else {
            throw ContainerImageLeaseError.corruptLease(
                reference: leaseReference,
                expected: expected.digest,
                actual: created.digest
            )
        }

        // Re-read the exact key. This is the commit point: a backend that
        // returned a stale tag result must never escape as a usable lease.
        guard
            let committed = try await store.list().first(where: {
                $0.reference == leaseReference
            })
        else {
            throw ContainerImageLeaseError.leaseMissing(
                reference: leaseReference,
                digest: expected.digest
            )
        }
        guard committed.digest == expected.digest else {
            throw ContainerImageLeaseError.corruptLease(
                reference: leaseReference,
                expected: expected.digest,
                actual: committed.digest
            )
        }
        return ContainerImageLease(image: committed)
    }

    func verify(_ lease: ContainerImageLease) async throws {
        guard
            let current = try await store.list().first(where: {
                $0.reference == lease.reference
            })
        else {
            throw ContainerImageLeaseError.leaseMissing(
                reference: lease.reference,
                digest: lease.rootDigest
            )
        }
        guard current.digest == lease.rootDigest else {
            throw ContainerImageLeaseError.corruptLease(
                reference: lease.reference,
                expected: lease.rootDigest,
                actual: current.digest
            )
        }
    }

    func release(_ lease: ContainerImageLease) async throws {
        guard
            let current = try await store.list().first(where: {
                $0.reference == lease.reference
            })
        else {
            return
        }
        guard current.digest == lease.rootDigest else {
            throw ContainerImageLeaseError.corruptLease(
                reference: lease.reference,
                expected: lease.rootDigest,
                actual: current.digest
            )
        }
        try await store.delete(reference: lease.reference)
    }
}

protocol ContainerImageLeaseReconciling: Sendable {
    /// Reconciles the root after a lifecycle mutation. When `reservation` is
    /// supplied, its release and the remaining-use check happen under the same
    /// image-mutation writer, so prune cannot observe a false ownerless gap.
    func reconcile(
        rootDescriptor: Descriptor,
        releasing reservation: ContainerImageLeaseReservation?
    ) async
}

extension ContainerImageLeaseReconciling {
    func reconcile(rootDescriptor: Descriptor) async {
        await reconcile(rootDescriptor: rootDescriptor, releasing: nil)
    }
}

/// Releases an immutable runtime lease only after the native container store
/// proves that no running or stopped container still owns its root.
///
/// The remaining-use check and exact-key removal execute under the same image
/// mutation lock used by create and image deletion. Cleanup runs detached from
/// request cancellation because the native container deletion has already
/// committed; a cancelled HTTP client must not leak the lease indefinitely.
struct LiveContainerImageLeaseReconciler: ContainerImageLeaseReconciling {
    private let mutationCoordinator: ImageMutationCoordinator
    private let containerInventoryProvider: any ContainerSnapshotInventoryProviding
    private let leaseManager: any ContainerImageLeasing
    private let referenceStore: any ImageReferenceStore
    private let identityResolver: ImageIdentityResolver?
    private let reservationRegistry: ContainerImageLeaseReservationRegistry
    private let logger: Logger

    init(
        mutationCoordinator: ImageMutationCoordinator,
        containerInventoryProvider: any ContainerSnapshotInventoryProviding =
            LiveContainerSnapshotInventoryProvider(),
        leaseManager: any ContainerImageLeasing =
            LiveContainerImageLeaseManager(),
        referenceStore: any ImageReferenceStore = LiveImageReferenceStore(),
        identityResolver: ImageIdentityResolver? = nil,
        reservationRegistry: ContainerImageLeaseReservationRegistry = .shared,
        logger: Logger = Logger(label: "glassdock.image-lease-reconciler")
    ) {
        self.mutationCoordinator = mutationCoordinator
        self.containerInventoryProvider = containerInventoryProvider
        self.leaseManager = leaseManager
        self.referenceStore = referenceStore
        self.identityResolver = identityResolver
        self.reservationRegistry = reservationRegistry
        self.logger = logger
    }

    func reconcile(
        rootDescriptor: Descriptor,
        releasing reservation: ContainerImageLeaseReservation? = nil
    ) async {
        let task = Task.detached { [self] in
            do {
                try await mutationCoordinator.performMutation {
                    // Release this create pipeline's token only after admission
                    // to the writer. Prune cannot enter between token release
                    // and the inventory/other-reservation checks below.
                    if let reservation {
                        await reservationRegistry.release(reservation)
                    }
                    let hasActiveReservation =
                        await reservationRegistry
                        .isReserved(rootDigest: rootDescriptor.digest)
                    guard !hasActiveReservation else {
                        return
                    }

                    let containers =
                        try await containerInventoryProvider
                        .containers()
                    guard
                        !containers.contains(where: {
                            $0.configuration.image.digest
                                == rootDescriptor.digest
                        })
                    else {
                        return
                    }

                    let lease = ContainerImageLease(
                        image: ClientImage(
                            description: ImageDescription(
                                reference: ContainerImageLease.reference(
                                    for: rootDescriptor.digest
                                ),
                                descriptor: rootDescriptor
                            )
                        )
                    )
                    try await leaseManager.release(lease)
                    _ = try? await referenceStore.cleanUpOrphanedBlobs()
                    await identityResolver?.invalidate()
                }
            } catch {
                logger.warning(
                    "Failed to reconcile runtime image lease for \(rootDescriptor.digest): \(error)"
                )
            }
        }
        await task.value
    }
}

/// Process-wide bridge for lifecycle paths whose detached observers are not
/// constructed through Vapor dependency injection (notably `--rm`). Production
/// installs the exact reconciler sharing the daemon's image mutation coordinator.
actor ContainerImageLeaseReconcilerRegistry {
    static let shared = ContainerImageLeaseReconcilerRegistry()

    private var reconciler: (any ContainerImageLeaseReconciling)?

    func configure(_ reconciler: any ContainerImageLeaseReconciling) {
        self.reconciler = reconciler
    }

    func reconcile(
        rootDescriptor: Descriptor,
        releasing reservation: ContainerImageLeaseReservation? = nil
    ) async {
        await reconciler?.reconcile(
            rootDescriptor: rootDescriptor,
            releasing: reservation
        )
    }
}

struct RegisteredContainerImageLeaseReconciler:
    ContainerImageLeaseReconciling
{
    func reconcile(
        rootDescriptor: Descriptor,
        releasing reservation: ContainerImageLeaseReservation? = nil
    ) async {
        await ContainerImageLeaseReconcilerRegistry.shared.reconcile(
            rootDescriptor: rootDescriptor,
            releasing: reservation
        )
    }
}
