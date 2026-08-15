import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress

/// What was removed when deleting an image reference.
/// Mirrors Docker Engine's `ImageDeleteResponseItem` semantics:
///   - `untagged` — the tag that was removed (always present)
///   - `digest` — the sha256 of the image the tag pointed at (always present); Docker uses
///     this as the `Actor.ID` for `untag`/`delete` events
///   - `deletedDigest` — the sha256 of image layers freed (only when the last tag was removed)
struct ImageDeletionResult {
    let untagged: String  // normalized tag that was untagged
    let additionalUntagged: [String]
    let digest: String  // sha256 of the image the removed tag referenced
    let deletedDigest: String?  // sha256 if the image layers were garbage-collected
    let reclaimedBytes: Int64

    init(
        untagged: String,
        additionalUntagged: [String] = [],
        digest: String,
        deletedDigest: String?,
        reclaimedBytes: Int64 = 0
    ) {
        self.untagged = untagged
        self.additionalUntagged = additionalUntagged
        self.digest = digest
        self.deletedDigest = deletedDigest
        self.reclaimedBytes = reclaimedBytes
    }

    var untaggedReferences: [String] {
        [untagged] + additionalUntagged
    }
}

protocol ClientImageProtocol: Sendable {
    func list(includeSystemImages: Bool) async throws -> [ClientImage]
    func delete(id: String) async throws -> ImageDeletionResult
    func delete(id: String, force: Bool) async throws -> ImageDeletionResult
    func pull(
        image: String,
        tag: String?,
        platform: Platform,
        fallbackPolicy: PlatformFallbackPolicy,
        logger: Logger
    ) async throws -> AsyncThrowingStream<
        PullProgress, Error
    >
    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<
        String, Error
    >
    func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64)
    func load(tarballPath: URL, platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String]
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL
    func importImage(
        tarPath: URL,
        repo: String?,
        tag: String?,
        message: String?,
        changes: [String],
        platform: Platform,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> (reference: String?, digest: String)
}

protocol ImageTaggingProtocol: Sendable {
    func tag(source: String, target: String) async throws -> ImageTaggingResult
}

protocol ImageConfigIdentityProviding: Sendable {
    func configDigestsByReference() async -> [String: String]
    func configDigest(for reference: String) async -> String?
}

struct SavedImageArchive: Sendable {
    let url: URL
    let actorIDs: [String]
}

struct LoadedImageArchive: Sendable {
    let references: [String]
    let actorIDs: [String]
}

protocol ImageLoadingWithIdentity: Sendable {
    func loadWithIdentities(
        tarballPath: URL,
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> LoadedImageArchive
}

/// Returns the archive and the immutable Docker config identities captured in
/// the same store read epoch. This prevents a concurrent retag after export
/// from changing which image a completed save event attributes.
protocol ImageSavingWithIdentity: Sendable {
    func saveWithIdentities(
        references: [String],
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> SavedImageArchive
}

struct DockerTagConfigSelection: Sendable, Equatable {
    let reference: String
    let rootDigest: String
    let configDigest: String
}

protocol DockerTagConfigSelectionProviding: Sendable {
    func dockerTagConfigSelections() async -> [DockerTagConfigSelection]
}

struct ImageTaggingResult: Sendable {
    let image: ClientImage
    let dockerConfigDigest: String
}

extension ClientImageProtocol {
    func list() async throws -> [ClientImage] {
        try await list(includeSystemImages: false)
    }

    func delete(id: String, force: Bool) async throws -> ImageDeletionResult {
        try await delete(id: id)
    }

    /// Store-reference → digest map used to shape save/load events like moby's, whose
    /// Actor.ID is the image digest. References the store cannot resolve fall back to
    /// the reference itself at the emission site.
    func digestsByReference() async -> [String: String] {
        if let provider = self as? any ImageConfigIdentityProviding {
            return await provider.configDigestsByReference()
        }
        return ((try? await list()) ?? []).reduce(into: [:]) {
            $0[$1.reference] = $1.digest
        }
    }
}

enum ClientImageError: Error, CustomStringConvertible {
    case notFound(id: String)
    case digestReferenceNotAllowed(repo: String)
    case conflict(String)

    var description: String {
        switch self {
        case .notFound(let id):
            return "No such image: \(id)"
        case .digestReferenceNotAllowed(let repo):
            return "cannot reference \(repo) by digest"
        case .conflict(let message):
            return message
        }
    }
}

enum PullProgress: Sendable {
    case message(String)
    case downloading(current: Int64, total: Int64)
    case extracting(current: Int64, total: Int64)
}

private struct ImageReplacementOutcome<Value: Sendable>: Sendable {
    let value: Value
    let assignments: [CanonicalImageAssignment]
}

private struct PulledImageIdentity: Sendable {
    let image: ClientImage
    let dockerConfigDigest: String
}

actor PullByteCounter {
    private var current: Int64 = 0
    private var total: Int64 = 0
    private var lastEmit: ContinuousClock.Instant?
    private let emitInterval: Duration

    init(emitInterval: Duration = .milliseconds(100)) {
        self.emitInterval = emitInterval
    }

    func apply(_ events: [ProgressUpdateEvent]) -> (current: Int64, total: Int64)? {
        var changed = false
        for event in events {
            switch event {
            case .addSize(let value): current += value
            case .setSize(let value): current = value
            case .addTotalSize(let value): total += value
            case .setTotalSize(let value): total = value
            default: continue
            }
            changed = true
        }
        guard changed, shouldEmitNow() else { return nil }
        lastEmit = .now
        return (current, total)
    }

    private func shouldEmitNow() -> Bool {
        if total > 0 && current >= total { return true }
        guard let lastEmit else { return true }
        return ContinuousClock.Instant.now - lastEmit >= emitInterval
    }
}

/// Seam that abstracts the static `ClientImage` API for testing.
/// The real implementation delegates to Apple Container; tests inject a fake.
protocol ImageDeletionStore: Sendable {
    /// Return the (normalizedReference, digest) for the image matching `id`.
    func normalizedReference(for id: String, config: ContainerSystemConfig) async throws -> (String, String)
    /// Return all normalized references that share the same digest.
    /// Call this AFTER delete() to determine whether the deletion freed the image layers.
    func refsForDigest(_ digest: String) async throws -> [String]
    /// Delete the image with the exact (normalized) reference from the store.
    func delete(reference: String) async throws
    /// Free orphaned blobs and snapshots no longer referenced by any image.
    /// Returns bytes reclaimed. Mirrors what Apple Container's own CLI does after
    /// every image delete or prune to actually reclaim disk space.
    func cleanUpOrphanedBlobs() async throws -> UInt64
}

/// Production implementation — delegates straight to Apple Container.
struct LiveImageDeletionStore: ImageDeletionStore {
    func normalizedReference(for id: String, config: ContainerSystemConfig) async throws -> (String, String) {
        let image = try await ClientImage.get(reference: id, containerSystemConfig: config)
        return (image.reference, image.digest)
    }

    func refsForDigest(_ digest: String) async throws -> [String] {
        let all = try await ClientImage.list()
        return all.filter { $0.digest == digest }.map { $0.reference }
    }

    func delete(reference: String) async throws {
        // garbageCollect: false — Apple Container's own CLI always uses false here.
        // Orphaned blobs are freed separately via cleanUpOrphanedBlobs().
        try await ClientImage.delete(reference: reference, garbageCollect: false)
    }

    func cleanUpOrphanedBlobs() async throws -> UInt64 {
        let (_, freed) = try await ClientImage.cleanUpOrphanedBlobs()
        return freed
    }
}

struct ClientImageService: ClientImageProtocol, ImageTaggingProtocol,
    ImageConfigIdentityProviding,
    ImageSavingWithIdentity,
    ImageLoadingWithIdentity,
    DockerTagConfigSelectionProviding,
    ImageStoreInventoryProviding
{
    private let containerSystemConfig: ContainerSystemConfig
    private let identityResolver: ImageIdentityResolver
    private let mutationCoordinator: ImageMutationCoordinator
    private let referenceStore: any ImageReferenceStore
    private let referenceManager: CanonicalImageReferenceManager
    private let referenceConstraintStore: ImageReferenceConstraintStore
    private let archiveLoader: any ImageArchiveLoading
    private let imagePuller: any ImagePulling
    private let imagePusher: any ImagePushing
    private let runnableImageSelector: RunnableImageSelector
    private let containerInventoryProvider: any ContainerSnapshotInventoryProviding
    private let imageLeaseReservations: ContainerImageLeaseReservationRegistry

    init(
        containerSystemConfig: ContainerSystemConfig,
        identityResolver: ImageIdentityResolver? = nil,
        mutationCoordinator: ImageMutationCoordinator? = nil,
        referenceStore: any ImageReferenceStore = LiveImageReferenceStore(),
        archiveLoader: any ImageArchiveLoading = LiveImageArchiveLoader(),
        imagePuller: any ImagePulling = LiveImagePuller(),
        imagePusher: any ImagePushing = LiveImagePusher(),
        runnableImageSelector: RunnableImageSelector = RunnableImageSelector(),
        containerInventoryProvider: any ContainerSnapshotInventoryProviding =
            LiveContainerSnapshotInventoryProvider(),
        imageLeaseReservations: ContainerImageLeaseReservationRegistry = .shared
    ) {
        let coordinator = mutationCoordinator ?? identityResolver?.mutationCoordinator ?? ImageMutationCoordinator()
        self.containerSystemConfig = containerSystemConfig
        self.mutationCoordinator = coordinator
        self.identityResolver =
            identityResolver
            ?? ImageIdentityResolver(
                systemConfig: containerSystemConfig,
                mutationCoordinator: coordinator
            )
        self.referenceStore = referenceStore
        self.referenceManager = CanonicalImageReferenceManager(
            systemConfig: containerSystemConfig,
            store: referenceStore
        )
        self.referenceConstraintStore =
            self.identityResolver
            .referenceConstraintStore
        self.archiveLoader = archiveLoader
        self.imagePuller = imagePuller
        self.imagePusher = imagePusher
        self.runnableImageSelector = runnableImageSelector
        self.containerInventoryProvider = containerInventoryProvider
        self.imageLeaseReservations = imageLeaseReservations
    }

    private func replacingImages<Value: Sendable>(
        targeting references: [String],
        operation: @Sendable @escaping () async throws -> ImageReplacementOutcome<Value>,
        afterCommit: (@Sendable (Value) async -> Value)? = nil
    ) async throws -> Value {
        try await mutationCoordinator.performMutation { [self] in
            // Cancel any catalog hydration that began before this writer was
            // admitted. Writer-side lookups must rebuild from this mutation's
            // starting state, never consume an intermediate reader snapshot.
            await identityResolver.invalidate()
            var prepared: PreparedImageReplacement?
            var constraintTransaction: ImageReferenceConstraintTransaction?
            do {
                try await referenceConstraintStore.reconcile(
                    currentRootByReference:
                        try await referenceManager.currentOwnerDigests()
                )
                var replacement = try await referenceManager.prepareToReplace(
                    references
                )
                prepared = replacement
                // Preservation may span several Apple store writes. Do not
                // begin the potentially expensive XPC operation after its
                // request was cancelled while those writes were in flight.
                try Task.checkCancellation()
                let outcome = try await operation()
                // Some Apple XPC calls complete successfully even after the
                // caller is cancelled. Treat cancellation observed before the
                // canonical-key commit as an operation failure so rollback
                // restores the previous owner.
                try Task.checkCancellation()
                replacement =
                    try await referenceManager
                    .prepareRepositoryDigestAssignments(
                        outcome.assignments,
                        prepared: replacement
                    )
                prepared = replacement
                let transaction = try await referenceConstraintStore.prepare(
                    outcome.assignments.compactMap { assignment in
                        guard
                            let canonical = referenceManager.canonicalTag(
                                assignment.targetReference
                            )
                        else {
                            return nil
                        }
                        return ImageReferenceConstraintAssignment(
                            reference: canonical,
                            rootDigest: assignment.image.digest,
                            constraint: assignment.variantConstraint
                        )
                    }
                )
                constraintTransaction = transaction
                try await referenceManager.commit(
                    outcome.assignments,
                    prepared: replacement
                )
                // The journal already makes the committed selector visible. A
                // failure to compact it must not turn a successful image/tag
                // mutation into a misleading retryable API error.
                try? await referenceConstraintStore.commit(transaction)
                await identityResolver.invalidate()
                if let afterCommit {
                    return await afterCommit(outcome.value)
                }
                return outcome.value
            } catch {
                if let prepared {
                    await referenceManager.rollbackUncancelled(prepared)
                }
                if constraintTransaction != nil,
                    let owners =
                        try? await referenceManager
                        .currentOwnerDigests()
                {
                    try? await referenceConstraintStore.reconcile(
                        currentRootByReference: owners
                    )
                }
                await identityResolver.invalidate()
                if case CanonicalImageReferenceError.conflictingAssignments(
                    let target
                ) = error {
                    throw ClientImageError.conflict(
                        "conflict: \(target) has conflicting image assignments"
                    )
                }
                throw error
            }
        }
    }

    func tag(source: String, target: String) async throws -> ImageTaggingResult {
        guard let canonicalTarget = referenceManager.canonicalTag(target) else {
            throw ClientImageError.notFound(id: target)
        }
        return try await mutationCoordinator.performMutation { [self] in
            await identityResolver.invalidate()
            try await referenceConstraintStore.reconcile(
                currentRootByReference:
                    try await referenceManager.currentOwnerDigests()
            )
            let resolved: ResolvedImageIdentity
            do {
                resolved = try await identityResolver.resolveDuringMutation(source)
            } catch let error as ImageIdentityResolutionError {
                if case .ambiguous = error {
                    throw ClientImageError.conflict("conflict: \(source) is an ambiguous image ID")
                }
                throw ClientImageError.notFound(id: source)
            }
            let owners = try await referenceManager.currentOwnerDigests()
            let plannedAssignment = ImageReferenceConstraintAssignment(
                reference: canonicalTarget,
                rootDigest: resolved.image.digest,
                constraint: resolved.variantConstraint
            )
            let transaction = try await referenceConstraintStore.prepare([
                plannedAssignment
            ])

            // When the logical target already owns this root, changing its OCI
            // selector is the entire Docker-visible mutation. The sidecar's
            // atomic file replacement is the commit point; rewriting Apple's
            // identical root cannot provide a crash witness and is unnecessary.
            if owners[canonicalTarget] == resolved.image.digest {
                try await referenceConstraintStore.commit(transaction)
                // Ownership is unchanged, but normalize a legacy familiar or
                // annotation-only Apple key so future exact store operations
                // (notably push) have a canonical registry-qualified source.
                let replacement = try await referenceManager.prepareToReplace([
                    canonicalTarget
                ])
                try await referenceManager.commit(
                    [
                        CanonicalImageAssignment(
                            targetReference: canonicalTarget,
                            image: resolved.image,
                            variantConstraint: resolved.variantConstraint
                        )
                    ],
                    prepared: replacement
                )
                guard
                    let committed = try await referenceManager.exactImage(
                        reference: canonicalTarget
                    ), committed.digest == resolved.image.digest
                else {
                    throw CanonicalImageReferenceError.replacementMissing(
                        target: canonicalTarget,
                        digest: resolved.image.digest
                    )
                }
                await identityResolver.invalidate()
                return ImageTaggingResult(
                    image: committed,
                    dockerConfigDigest: resolved.dockerConfigDigest
                )
            }

            var prepared: PreparedImageReplacement?
            do {
                let replacement = try await referenceManager.prepareToReplace([
                    canonicalTarget
                ])
                prepared = replacement
                try Task.checkCancellation()
                let tagged = try await referenceManager.tagExact(
                    sourceReference: resolved.reference,
                    targetReference: canonicalTarget
                )
                try Task.checkCancellation()
                try await referenceManager.commit(
                    [
                        CanonicalImageAssignment(
                            targetReference: canonicalTarget,
                            image: tagged,
                            variantConstraint: resolved.variantConstraint
                        )
                    ],
                    prepared: replacement
                )
                try? await referenceConstraintStore.commit(transaction)
                await identityResolver.invalidate()
                return ImageTaggingResult(
                    image: tagged,
                    dockerConfigDigest: resolved.dockerConfigDigest
                )
            } catch {
                if let prepared {
                    await referenceManager.rollbackUncancelled(prepared)
                }
                if let currentOwners =
                    try? await referenceManager
                    .currentOwnerDigests()
                {
                    try? await referenceConstraintStore.reconcile(
                        currentRootByReference: currentOwners
                    )
                }
                await identityResolver.invalidate()
                throw error
            }
        }
    }

    // Workaround for narrowing an unspecified push from all platforms to a single platform available.
    // This avoids container push failures caused by missing blobs for non local platforms.
    func resolvedPushPlatform(for image: ClientImage, requestedPlatform: Platform?, logger: Logger) async throws -> Platform? {
        guard requestedPlatform == nil else {
            return requestedPlatform
        }

        let descriptors = try await runnableImageSelector.descriptors(
            for: image
        )
        // A platform-filtered Apple push omits descriptors outside that
        // platform, including standard unknown/unknown attestations. Preserve
        // the complete OCI graph whenever artifacts are attached.
        if descriptors.contains(where: { $0.kind == .artifact }) {
            return nil
        }
        let availablePlatforms = Array(
            Set(descriptors.compactMap(\.runnableVariant?.platform))
        )

        if availablePlatforms.count == 1 {
            return availablePlatforms[0]
        }

        return nil
    }

    func list(includeSystemImages: Bool = false) async throws -> [ClientImage] {
        try await mutationCoordinator.stableRead {
            try await listUncoordinated(includeSystemImages: includeSystemImages)
        }
    }

    func configDigestsByReference() async -> [String: String] {
        guard let images = try? await list() else { return [:] }
        var result: [String: String] = [:]
        for image in images {
            if let resolved = try? await identityResolver.resolve(
                image.reference
            ) {
                result[image.reference] = resolved.dockerConfigDigest
            }
        }
        return result
    }

    func configDigest(for reference: String) async -> String? {
        try? await identityResolver.resolve(reference).dockerConfigDigest
    }

    func dockerTagConfigSelections() async -> [DockerTagConfigSelection] {
        guard let images = try? await list() else { return [] }
        var result: [DockerTagConfigSelection] = []
        for image in images {
            guard
                let selectionReference = Self.dockerSelectionReference(
                    image.reference,
                    referenceManager: referenceManager
                ),
                let resolved = try? await identityResolver.resolve(
                    selectionReference
                )
            else { continue }
            result.append(
                .init(
                    reference: selectionReference,
                    rootDigest: resolved.image.digest,
                    configDigest: resolved.dockerConfigDigest
                )
            )
        }
        return result
    }

    private static func dockerSelectionReference(
        _ reference: String,
        referenceManager: CanonicalImageReferenceManager
    ) -> String? {
        if let canonical = referenceManager.canonicalTag(reference) {
            return canonical
        }
        guard
            !DockerImageReferenceSemantics.isInternalReference(reference),
            !DockerImageReferenceSemantics.isBareSHA256Identifier(reference),
            let parsed = try? Reference.parse(reference),
            parsed.digest != nil
        else { return nil }
        return reference
    }

    func imageStoreInventory(
        includeSystemImages: Bool
    ) async throws -> ImageStoreInventory {
        try await mutationCoordinator.stableRead { [self] in
            try await imageStoreInventoryUncoordinated(
                includeSystemImages: includeSystemImages
            )
        }
    }

    private func listUncoordinated(
        includeSystemImages: Bool
    ) async throws -> [ClientImage] {
        try await imageStoreInventoryUncoordinated(
            includeSystemImages: includeSystemImages
        ).images
    }

    private func imageStoreInventoryUncoordinated(
        includeSystemImages: Bool
    ) async throws -> ImageStoreInventory {
        let physicalImages = try await referenceStore.list()
        let containers =
            (try? await containerInventoryProvider.containers())
            ?? []
        let activeLeaseRoots = Set(
            ContainerImageIdentity.usageByRootDigest(containers).keys
        ).union(await imageLeaseReservations.reservedRootDigests())
        let allImages = referenceManager.dockerVisibleImages(
            physicalImages,
            activeLeaseRootDigests: activeLeaseRoots
        )
        let visibleImages: [ClientImage]
        if includeSystemImages {
            visibleImages = allImages
        } else {
            visibleImages = allImages.filter { image in
                let reference = image.reference.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let isDigest = reference.contains("@sha256:")
                let isInfra = Utility.isInfraImage(
                    name: reference,
                    builderImage: containerSystemConfig.build.image,
                    initImage: containerSystemConfig.vminit.image
                )
                return isDigest || !isInfra
            }
        }

        let physicalReferences = Dictionary(
            grouping: physicalImages,
            by: \.digest
        ).mapValues { images in
            Set(images.map(\.reference).filter { !$0.isEmpty })
        }
        var tagSelections: [DockerTagConfigSelection] = []
        for image in visibleImages {
            guard
                let selectionReference = Self.dockerSelectionReference(
                    image.reference,
                    referenceManager: referenceManager
                ),
                let resolved =
                    try? await identityResolver
                    .resolveDuringMutation(selectionReference)
            else { continue }
            tagSelections.append(
                .init(
                    reference: selectionReference,
                    rootDigest: resolved.image.digest,
                    configDigest: resolved.dockerConfigDigest
                )
            )
        }
        return ImageStoreInventory(
            images: visibleImages,
            physicalReferencesByRootDigest: physicalReferences,
            tagConfigSelections: tagSelections
        )
    }

    func delete(id: String) async throws -> ImageDeletionResult {
        try await delete(id: id, force: false)
    }

    func delete(id: String, force: Bool) async throws -> ImageDeletionResult {
        try await mutationCoordinator.performMutation { [self] in
            await identityResolver.invalidate()
            do {
                let result = try await deleteDuringMutation(id: id, force: force)
                await identityResolver.invalidate()
                return result
            } catch {
                await identityResolver.invalidate()
                throw error
            }
        }
    }

    private func deleteDuringMutation(id: String, force: Bool) async throws -> ImageDeletionResult {
        let resolved: ResolvedImageIdentity
        do {
            resolved = try await identityResolver.resolveDuringMutation(id)
        } catch let error as ImageIdentityResolutionError {
            if case .ambiguous = error {
                throw ClientImageError.conflict("conflict: \(id) is an ambiguous image ID")
            }
            throw ClientImageError.notFound(id: id)
        }
        let logicalReferences = Array(
            Set(resolved.references.compactMap(referenceManager.canonicalTag))
        ).sorted()
        let selectedRepositoryDigest = resolved.selectedStoreReference.flatMap {
            Self.repositoryDigestStoreReference($0) ? $0 : nil
        }
        let deletionKind: ImageIdentityKind =
            selectedRepositoryDigest == nil ? resolved.kind : .reference
        _ = try Self.deletionReferences(
            kind: deletionKind,
            resolvedReference: resolved.reference,
            allReferences: logicalReferences,
            requestedID: id,
            force: force
        )
        let canonicalTarget = referenceManager.canonicalTag(id)
        let removesFinalDockerReference = Self.deletionRemovesFinalDockerReference(
            kind: deletionKind,
            resolvedReference: resolved.reference,
            canonicalTarget: canonicalTarget,
            selectedRepositoryDigest: selectedRepositoryDigest,
            logicalReferences: logicalReferences,
            storeReferences: resolved.storeReferences
        )
        let ownerRoots = resolved.rootDigests
        let allContainers = try await containerInventoryProvider.containers()
        let deletesWholeRoot =
            deletionKind == .root
            && resolved.variantConstraint == .unconstrained
        // Docker conflict semantics are scoped to the selected config (except
        // an unconstrained root deletion), while physical retention is scoped
        // to the whole OCI root. A multi-platform/multi-config root can have a
        // container using config B while config A is deleted legitimately.
        let containersUsingSelectedIdentity = allContainers.filter {
            ContainerImageIdentity.matches(
                $0,
                rootDigests: ownerRoots,
                configDigest: resolved.dockerConfigDigest,
                wholeRoot: deletesWholeRoot
            )
        }
        let containersUsingOwnerRoots = allContainers.filter {
            ownerRoots.contains($0.configuration.image.digest)
        }
        var reservedRoots: Set<String> = []
        for root in ownerRoots
        where await imageLeaseReservations.isReserved(
            rootDigest: root
        ) {
            reservedRoots.insert(root)
        }
        let rootHasCreateReservation = !reservedRoots.isEmpty
        if removesFinalDockerReference {
            let immutableIDDeletion = deletionKind != .reference
            if immutableIDDeletion,
                let runningContainer = containersUsingSelectedIdentity.first(where: {
                    $0.status == .running || $0.status == .stopping
                })
            {
                throw Self.imageInUseConflict(
                    requestedID: id,
                    container: runningContainer,
                    forceCannotOverride: true
                )
            }
            if immutableIDDeletion, rootHasCreateReservation {
                throw Self.imageReservedByCreateConflict(
                    requestedID: id,
                    forceCannotOverride: true
                )
            }
            if !force {
                if let container = containersUsingSelectedIdentity.first {
                    throw Self.imageInUseConflict(
                        requestedID: id,
                        container: container,
                        forceCannotOverride: false
                    )
                }
                if rootHasCreateReservation {
                    throw Self.imageReservedByCreateConflict(
                        requestedID: id,
                        forceCannotOverride: false
                    )
                }
            }
        }

        var references: [String]
        let responseReferences: [String]
        if let selectedRepositoryDigest {
            // A named digest is a reference association even though it selects
            // manifest/config identity for inspect and container creation.
            // Remove only the exact store key and retain sibling tags.
            references = [selectedRepositoryDigest]
            responseReferences = [selectedRepositoryDigest]
        } else if resolved.kind == .reference,
            let canonicalTarget
        {
            // Retire every physical spelling of the one logical Docker tag.
            // Preserve displaced roots before removing their stale keys so a
            // later refresh cannot resurrect the tag from historical aliases.
            _ = try await referenceManager.prepareToRemove(
                canonicalTarget,
                currentOwnerDigest: resolved.image.digest
            )
            references = try await referenceManager.physicalReferences(
                claiming: canonicalTarget
            )
            responseReferences = [canonicalTarget]
        } else if resolved.kind == .reference {
            references = [resolved.reference]
            responseReferences = [resolved.reference]
        } else {
            // Deleting by OCI root/manifest/config ID removes the Docker-visible
            // tags owned by that root, not merely Apple's representative key.
            // Retire each logical tag first so a stale familiar key on a displaced
            // root cannot reclaim ownership after the exact canonical key is gone.
            var claimingReferences: [String] = []
            for canonicalTarget in logicalReferences {
                guard
                    let owner = resolved.owners.first(where: {
                        $0.references.contains(canonicalTarget)
                    })
                else { continue }
                _ = try await referenceManager.prepareToRemove(
                    canonicalTarget,
                    currentOwnerDigest: owner.image.digest
                )
                claimingReferences.append(
                    contentsOf: try await referenceManager.physicalReferences(
                        claiming: canonicalTarget
                    )
                )
            }

            let claimingSet = Set(claimingReferences)
            var immutableOwnerReferences: [String] = []
            for owner in resolved.owners {
                let physical = try await referenceManager.physicalReferences(
                    forDigest: owner.image.digest
                )
                let selectedRepositoryDigests = Self.repositoryDigests(
                    ownedBy: owner,
                    selectedBy: resolved
                )
                let selectedPhysical = physical.filter {
                    claimingSet.contains($0)
                        || selectedRepositoryDigests.contains($0)
                }
                immutableOwnerReferences.append(contentsOf: selectedPhysical)

                let remainingRealReference = physical.contains { reference in
                    !selectedPhysical.contains(reference)
                        && !DockerImageReferenceSemantics.isInternalReference(
                            reference
                        )
                }
                if !remainingRealReference {
                    immutableOwnerReferences.append(
                        contentsOf: physical.filter {
                            DockerImageReferenceSemantics.isInternalReference(
                                $0
                            )
                        }
                    )
                }
            }
            references = Self.uniqueReferencesPreservingOrder(
                immutableOwnerReferences + claimingReferences
            )
            responseReferences =
                logicalReferences.isEmpty
                ? Array(references.prefix(1))
                : logicalReferences
        }
        guard let firstReference = references.first else {
            throw ClientImageError.notFound(id: id)
        }

        if !containersUsingOwnerRoots.isEmpty || rootHasCreateReservation {
            // `prepareToRemove` deliberately retires redundant dangling markers
            // for ordinary image deletion. An in-use root is different: Apple
            // resolves the exact immutable lease again when a stopped container
            // restarts. Reacquire it after canonical-tag preparation and exclude
            // it from deletion so both the content and the runtime key survive.
            let leaseManager = LiveContainerImageLeaseManager(
                store: referenceStore
            )
            for owner in resolved.owners
            where containersUsingOwnerRoots.contains(where: {
                $0.configuration.image.digest == owner.image.digest
            }) || reservedRoots.contains(owner.image.digest) {
                let ownerIdentity = ResolvedImageIdentity(
                    image: owner.image,
                    reference: owner.image.reference,
                    references: owner.references,
                    storeReferences: owner.storeReferences,
                    repositoryDigests: owner.repositoryDigests,
                    selectedStoreReference: nil,
                    kind: resolved.kind,
                    variantConstraint: resolved.variantConstraint,
                    owners: [owner],
                    dockerConfigDigest: resolved.dockerConfigDigest
                )
                let lease = try await leaseManager.acquire(for: ownerIdentity)
                references.removeAll { $0 == lease.reference }
            }
        }

        for reference in references {
            try await deleteExactReference(reference)
        }
        let reclaimedBytes =
            (try? await referenceStore.cleanUpOrphanedBlobs()).map {
                Int64(clamping: $0)
            } ?? 0
        // Deletion has committed at this point. A transient observation failure
        // must not turn a successful untag into an API error whose retry becomes
        // a confusing 404. Conservatively report no reclaimed digest when the
        // remaining-reference check is unavailable.
        let currentOwnerStillReferenced =
            (try? await referenceStore.list().contains {
                ownerRoots.contains($0.digest)
            }) ?? true
        return ImageDeletionResult(
            untagged: responseReferences.first ?? firstReference,
            additionalUntagged: Array(responseReferences.dropFirst()),
            digest: resolved.dockerConfigDigest,
            deletedDigest: currentOwnerStillReferenced
                ? nil : resolved.dockerConfigDigest,
            reclaimedBytes: currentOwnerStillReferenced ? 0 : reclaimedBytes
        )
    }

    /// Internal preservation keys intentionally have no resolver alias. Prune
    /// already holds the image mutation lock and has an immutable physical-row
    /// snapshot, so validate that exact key/root pair immediately before removal
    /// instead of routing it back through Docker's public identity namespace.
    private func deleteExactPhysicalImageDuringMutation(
        _ image: ClientImage
    ) async throws -> ImageDeletionResult {
        let dockerConfigDigest = await ContainerImageIdentity.configDigest(
            for: image,
            runnableImageSelector: runnableImageSelector
        )
        guard
            try await referenceStore.list().contains(where: {
                $0.reference == image.reference && $0.digest == image.digest
            })
        else {
            throw ClientImageError.notFound(id: image.reference)
        }
        try await referenceStore.delete(reference: image.reference)
        let reclaimedBytes =
            (try? await referenceStore.cleanUpOrphanedBlobs()).map {
                Int64(clamping: $0)
            } ?? 0
        let rootStillReferenced =
            (try? await referenceStore.list().contains {
                $0.digest == image.digest
            }) ?? true
        return ImageDeletionResult(
            untagged: image.reference,
            digest: dockerConfigDigest,
            deletedDigest: rootStillReferenced ? nil : dockerConfigDigest,
            reclaimedBytes: rootStillReferenced ? 0 : reclaimedBytes
        )
    }

    /// Delete the exact physical key selected by the canonical resolver. Calling
    /// Apple's `ClientImage.get` here is unsafe because it prefers historical
    /// name annotations and can select a displaced `moby-dangling` root.
    private func deleteExactReference(_ reference: String) async throws {
        guard try await referenceStore.list().contains(where: { $0.reference == reference }) else {
            throw ClientImageError.notFound(id: reference)
        }
        try await referenceStore.delete(reference: reference)
    }

    private static func uniqueReferencesPreservingOrder(_ references: [String]) -> [String] {
        var seen: Set<String> = []
        return references.filter { seen.insert($0).inserted }
    }

    private static func repositoryDigestStoreReference(
        _ reference: String
    ) -> Bool {
        guard !DockerImageReferenceSemantics.isBareSHA256Identifier(reference),
            !ContainerImageLease.isReference(reference),
            !reference.hasPrefix("moby-dangling@sha256:"),
            !reference.hasPrefix("untagged@sha256:"),
            let parsed = try? Reference.parse(reference),
            parsed.digest != nil
        else {
            return false
        }
        return true
    }

    private static func repositoryDigests(
        ownedBy owner: ResolvedImageOwner,
        selectedBy identity: ResolvedImageIdentity
    ) -> Set<String> {
        let selectedDigest: String?
        switch identity.variantConstraint {
        case .exactManifest(let manifestDigest, _):
            selectedDigest = manifestDigest
        case .descendantOfIndex(let indexDigest):
            selectedDigest = indexDigest
        case .unconstrained:
            selectedDigest =
                identity.kind == .root
                ? owner.image.digest : nil
        }
        guard let selectedDigest else { return [] }
        let canonical =
            selectedDigest.hasPrefix("sha256:")
            ? selectedDigest : "sha256:\(selectedDigest)"
        return Set(
            owner.repositoryDigests.filter { reference in
                guard let parsed = try? Reference.parse(reference),
                    let digest = parsed.digest
                else { return false }
                let value =
                    digest.hasPrefix("sha256:")
                    ? digest : "sha256:\(digest)"
                return value == canonical
            })
    }

    static func deletionRemovesFinalDockerReference(
        kind: ImageIdentityKind,
        resolvedReference: String,
        canonicalTarget: String?,
        selectedRepositoryDigest: String?,
        logicalReferences: [String],
        storeReferences: [String]
    ) -> Bool {
        let logicalTags = Set(logicalReferences)
        let physicalRepositoryDigests = Set(
            storeReferences.filter(repositoryDigestStoreReference)
        )

        if let selectedRepositoryDigest {
            return logicalTags.isEmpty
                && physicalRepositoryDigests.subtracting([
                    selectedRepositoryDigest
                ]).isEmpty
        }

        if kind == .reference {
            if let canonicalTarget {
                return logicalTags.subtracting([canonicalTarget]).isEmpty
                    && physicalRepositoryDigests.isEmpty
            }
            return logicalTags.isEmpty
                && physicalRepositoryDigests.subtracting([
                    resolvedReference
                ]).isEmpty
        }

        // Root, manifest, and config deletion remove every tag and physical
        // repository-digest association owned by the selected OCI root.
        return true
    }

    private static func imageInUseConflict(
        requestedID: String,
        container: ContainerSnapshot,
        forceCannotOverride: Bool
    ) -> ClientImageError {
        let state: String
        switch container.status {
        case .running, .stopping:
            state = "running"
        case .stopped, .unknown:
            state = "stopped"
        }
        let forcePhrase =
            forceCannotOverride
            ? "cannot be forced" : "must be forced"
        return .conflict(
            "conflict: unable to delete \(requestedID) (\(forcePhrase)) - image is being used by \(state) container \(container.id)"
        )
    }

    private static func imageReservedByCreateConflict(
        requestedID: String,
        forceCannotOverride: Bool
    ) -> ClientImageError {
        let forcePhrase =
            forceCannotOverride
            ? "cannot be forced" : "must be forced"
        return .conflict(
            "conflict: unable to delete \(requestedID) (\(forcePhrase)) - image is being used by an in-progress container create"
        )
    }

    static func deletionReferences(
        kind: ImageIdentityKind,
        resolvedReference: String,
        allReferences: [String],
        requestedID: String,
        force: Bool
    ) throws -> [String] {
        if kind == .reference {
            return [resolvedReference]
        }
        if allReferences.count > 1, !force {
            throw ClientImageError.conflict(
                "conflict: unable to delete \(requestedID) - image is referenced by multiple tags"
            )
        }
        return force ? allReferences.sorted() : [resolvedReference]
    }

    /// Deletes an image by reference, normalizing the key via `imageStore`.
    ///
    /// The `imageStore` parameter is a test seam that defaults to the real
    /// `ClientImage` implementation. Inject a custom store in tests to verify
    /// that the delete call uses the normalized reference (not the raw user input).
    ///
    /// **Bug fixed**: the pre-fix implementation passed the raw user-supplied `id`
    /// directly to the store's delete method. Because tags are stored under their
    /// normalized form (e.g. `"docker.io/library/test:latest"`), a short tag like
    /// `"test:latest"` would silently miss — the delete was a no-op.
    static func delete(
        id: String,
        containerSystemConfig: ContainerSystemConfig,
        imageStore: ImageDeletionStore = LiveImageDeletionStore()
    ) async throws -> ImageDeletionResult {
        let normalizedRef: String
        let digest: String
        do {
            (normalizedRef, digest) = try await imageStore.normalizedReference(for: id, config: containerSystemConfig)
        } catch {
            throw ClientImageError.notFound(id: id)
        }
        try await imageStore.delete(reference: normalizedRef)

        // Free orphaned blobs — mirrors Apple Container's own `container image rm`.
        // Use try? so a GC failure does not fail the delete: the tag is already gone
        // and returning an error here would cause the client to retry a completed operation.
        let reclaimedBytes =
            (try? await imageStore.cleanUpOrphanedBlobs()).map {
                Int64(clamping: $0)
            } ?? 0

        // Check remaining refs AFTER deletion to avoid a TOCTOU race: two concurrent
        // deletes checking before either delete would both see isLastRef=false and
        // neither would GC. Checking post-delete gives the accurate remaining count.
        // Use try? — if the list call fails the tag is still gone; assume last-ref=false.
        let remainingRefs = (try? await imageStore.refsForDigest(digest)) ?? []
        let wasLastRef = remainingRefs.isEmpty

        return ImageDeletionResult(
            untagged: normalizedRef,
            digest: digest,
            deletedDigest: wasLastRef ? digest : nil,
            reclaimedBytes: wasLastRef ? reclaimedBytes : 0
        )
    }

    func pull(
        image: String,
        tag: String?,
        platform: Platform,
        fallbackPolicy: PlatformFallbackPolicy,
        logger: Logger
    ) async throws -> AsyncThrowingStream<
        PullProgress, Error
    > {
        let reference = try {
            guard let tag, !tag.isEmpty else {
                return try ClientImage.normalizeReference(image, containerSystemConfig: containerSystemConfig)
            }

            let parsedReference = try Reference.parse(image)
            let updatedReference: Reference
            if tag.starts(with: "sha256:") {
                updatedReference = try parsedReference.withDigest(tag)
            } else {
                updatedReference = try parsedReference.withTag(tag)
            }
            return try ClientImage.normalizeReference(updatedReference.description, containerSystemConfig: containerSystemConfig)
        }()

        logger.info("Pulling image reference: \(reference)")

        return AsyncThrowingStream { continuation in
            logger.info("Starting to pull image \(reference) for platform \(platform.description)")
            continuation.yield(.message("Trying to pull \(reference)"))
            let task = Task {
                do {
                    let pulled = try await replacingImages(
                        targeting: [reference],
                        operation: {
                            var pullResult: PulledImageResult
                            do {
                                let byteCounter = PullByteCounter()
                                let unpackCounter = PullByteCounter()
                                pullResult = try await imagePuller.pullAndUnpack(
                                    reference: reference,
                                    platform: platform,
                                    containerSystemConfig: containerSystemConfig,
                                    downloadProgress: { progressEvents in
                                        for event in progressEvents {
                                            switch event {
                                            case .setDescription(let description),
                                                .setSubDescription(let description),
                                                .custom(let description):
                                                continuation.yield(.message(description))
                                            default:
                                                break
                                            }
                                        }
                                        if let bytes = await byteCounter.apply(progressEvents) {
                                            continuation.yield(.downloading(current: bytes.current, total: bytes.total))
                                        }
                                    },
                                    unpackProgress: { progressEvents in
                                        continuation.yield(.message("Unpacking image"))
                                        if let bytes = await unpackCounter.apply(progressEvents) {
                                            continuation.yield(.extracting(current: bytes.current, total: bytes.total))
                                        }
                                    }
                                )
                                logger.info("Successfully pulled image \(reference) for platform \(platform.description)")
                            } catch {
                                // On arm64 hosts: if the image has no arm64 variant,
                                // fall back to amd64 (Rosetta) inside the same tag
                                // replacement transaction.
                                let errMsg = String(describing: error)
                                guard fallbackPolicy == .allowRosetta,
                                    platform.architecture == "arm64",
                                    errMsg.contains("does not support required platforms")
                                else {
                                    throw error
                                }
                                let amd64 = Platform(arch: "amd64", os: platform.os, variant: nil)
                                logger.info("arm64 not available for \(reference), retrying with amd64 (Rosetta)")
                                continuation.yield(.message("linux/arm64 not available — retrying with linux/amd64 (Rosetta)"))
                                pullResult = try await imagePuller.pullAndUnpack(
                                    reference: reference,
                                    platform: amd64,
                                    containerSystemConfig: containerSystemConfig,
                                    downloadProgress: nil,
                                    unpackProgress: nil
                                )
                                logger.info("Successfully pulled \(reference) for amd64 (Rosetta)")
                            }
                            let pulled = pullResult.image
                            return ImageReplacementOutcome(
                                value: PulledImageIdentity(
                                    image: pulled,
                                    dockerConfigDigest: pulled.digest
                                ),
                                assignments: Self.pullAssignments(
                                    reference: reference,
                                    image: pulled,
                                    distributionDigest:
                                        pullResult.distributionDigest
                                )
                            )
                        },
                        afterCommit: { [identityResolver] pulled in
                            PulledImageIdentity(
                                image: pulled.image,
                                dockerConfigDigest: (try? await identityResolver
                                    .resolveDuringMutation(reference))?
                                    .dockerConfigDigest
                                    ?? pulled.image.digest
                            )
                        })
                    continuation.yield(
                        .message("Image digest: \(pulled.dockerConfigDigest)")
                    )
                    continuation.finish()
                } catch {
                    logger.error("Failed to pull image \(reference): \(error)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static func pullAssignments(
        reference: String,
        image: ClientImage,
        distributionDigest: String
    ) -> [CanonicalImageAssignment] {
        var assignments = [
            CanonicalImageAssignment(
                targetReference: reference,
                image: image
            )
        ]
        guard
            let parsed = try? Reference.parse(reference),
            parsed.digest == nil,
            let digestReference = try? parsed.withDigest(
                distributionDigest.hasPrefix("sha256:")
                    ? distributionDigest : "sha256:\(distributionDigest)"
            ).description
        else { return assignments }
        assignments.append(
            CanonicalImageAssignment(
                targetReference: digestReference,
                image: image
            )
        )
        return assignments
    }

    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<
        String, Error
    > {
        let output = AsyncThrowingStream<String, Error>.makeStream()
        let ready = AsyncThrowingStream<Void, Error>.makeStream()
        let task = Task {
            do {
                let pushReference: String
                if let canonical = referenceManager.canonicalTag(reference) {
                    // Apple push performs an exact store lookup and also requires
                    // a registry host. Reconcile a pre-existing familiar or
                    // annotation-only key before the non-idempotent registry
                    // operation; the canonical key then remains Docker's sole
                    // local owner after the push finishes.
                    _ = try await tag(source: reference, target: canonical)
                    pushReference = canonical
                } else {
                    pushReference = reference
                }
                try await mutationCoordinator.withMutationExcluded { [self] in
                    do {
                        let resolved: ResolvedImageIdentity
                        do {
                            resolved = try await identityResolver.resolve(pushReference)
                        } catch let error as ImageIdentityResolutionError {
                            if case .ambiguous = error {
                                throw ClientImageError.conflict(
                                    "conflict: \(pushReference) is an ambiguous image ID"
                                )
                            }
                            throw ClientImageError.notFound(id: pushReference)
                        }
                        let normalizedReference = resolved.reference
                        let image = resolved.image
                        if resolved.variantConstraint != .unconstrained {
                            if let platform,
                                let implied = resolved.impliedPlatform,
                                implied != platform
                            {
                                throw ClientImageError.conflict(
                                    "conflict: image \(pushReference) selects \(implied.description), not requested platform \(platform.description)"
                                )
                            }
                            // Apple's push API accepts only a stored root plus an
                            // optional platform. It cannot name an exact manifest
                            // when sibling manifests share a platform, nor a
                            // nested-index boundary. Broadening here would push a
                            // different Docker image than the tag denotes.
                            throw ClientImageError.conflict(
                                "conflict: pushing an exact manifest or nested-index image identity is not supported by Apple Container 1.2.1"
                            )
                        }
                        let effectivePlatform = try await resolvedPushPlatform(
                            for: image,
                            requestedPlatform: platform,
                            logger: logger
                        )
                        ready.continuation.yield(())
                        ready.continuation.finish()
                        let platformDescription =
                            effectivePlatform?.description
                            ?? "default"
                        logger.info(
                            "Starting to push image \(normalizedReference) for platform \(platformDescription)"
                        )
                        output.continuation.yield(
                            "Trying to push \(normalizedReference)"
                        )
                        try await imagePusher.push(
                            image: image,
                            platform: effectivePlatform,
                            scheme: .auto,
                            containerSystemConfig: containerSystemConfig,
                            progressUpdate: { progressEvents in
                                for event in progressEvents {
                                    switch event {
                                    case .setDescription(let description),
                                        .setSubDescription(let description),
                                        .setItemsName(let description),
                                        .custom(let description):
                                        output.continuation.yield(description)
                                    case .addTotalSize(let size),
                                        .setTotalSize(let size),
                                        .addSize(let size),
                                        .setSize(let size):
                                        let readableSize = ByteCountFormatter.string(
                                            fromByteCount: size,
                                            countStyle: .file
                                        )
                                        output.continuation.yield(
                                            "Uploaded \(readableSize)"
                                        )
                                    case .addTotalItems(let items),
                                        .setTotalItems(let items),
                                        .addItems(let items),
                                        .setItems(let items):
                                        output.continuation.yield(
                                            "Pushing \(items) layer\(items == 1 ? "" : "s")"
                                        )
                                    default:
                                        break
                                    }
                                }
                            }
                        )
                        logger.info(
                            "Successfully pushed image \(normalizedReference) for platform \(platformDescription)"
                        )
                        output.continuation.yield(
                            "Successfully pushed \(normalizedReference)"
                        )
                    } catch {
                        throw error
                    }
                }
                output.continuation.finish()
            } catch {
                logger.error("Failed to push image \(reference): \(error)")
                ready.continuation.finish(throwing: error)

                let errorDescription = String(describing: error)
                if errorDescription.contains("notFound")
                    && errorDescription.contains("Content with digest")
                {
                    let message =
                        "Failed to push image: One or more layers are missing from the image store. "
                        + "This is a known limitation of Apple's Containerization framework when working with tagged images. "
                        + "The tag metadata exists but the underlying layer data is not properly linked. "
                        + "Original error: \(errorDescription)"
                    output.continuation.yield(message)
                } else {
                    output.continuation.yield(errorDescription)
                }
                output.continuation.finish(throwing: error)
            }
        }
        output.continuation.onTermination = { @Sendable _ in
            task.cancel()
        }

        var readyIterator = ready.stream.makeAsyncIterator()
        let readiness: Void?
        do {
            readiness = try await withTaskCancellationHandler {
                try await readyIterator.next()
            } onCancel: {
                // The output stream has not been returned yet, so its
                // onTermination callback cannot cancel this unstructured task.
                // Forward request cancellation through the readiness handshake.
                task.cancel()
            }
            try Task.checkCancellation()
        } catch {
            task.cancel()
            throw error
        }
        guard readiness != nil else {
            task.cancel()
            throw ClientImageError.notFound(id: reference)
        }
        return output.stream
    }

    func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
        try await mutationCoordinator.performMutation { [self] in
            await identityResolver.invalidate()
            do {
                let result = try await pruneDuringMutation(
                    filters: filters,
                    logger: logger
                )
                await identityResolver.invalidate()
                return result
            } catch {
                await identityResolver.invalidate()
                throw error
            }
        }
    }

    private func pruneDuringMutation(
        filters: [String: [String]],
        logger: Logger
    ) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
        var allImages = try await listUncoordinated(
            includeSystemImages: false
        )
        // Runtime leases are deliberately hidden from Docker image listing.
        // Prune still owns reconciliation of orphan leases left by a crashed or
        // failed container create, so merge those exact physical rows into this
        // internal inventory without publishing them through list/inspect.
        let visiblePhysicalReferences = Set(allImages.map(\.reference))
        allImages.append(
            contentsOf: try await referenceStore.list().filter {
                ContainerImageLease.isReference($0.reference)
                    && !visiblePhysicalReferences.contains($0.reference)
            }
        )
        var imagesToDelete: [ClientImage] = []

        let allContainers = try await containerInventoryProvider.containers()
        let reservedRoots = await imageLeaseReservations.reservedRootDigests()
        let imagesInUse = Set(
            ContainerImageIdentity.usageByRootDigest(allContainers).keys
        ).union(reservedRoots)

        for image in allImages {
            var shouldDelete = false
            let reference = image.reference

            let isRuntimeLease = ContainerImageLease.isReference(reference)

            do {
                if imagesInUse.contains(image.digest) {
                    continue
                }

                // A lease with no owning container is a crash/failed-create
                // orphan. Reconcile it as dangling content by exact physical
                // identity; active leases were excluded by the root check above.
                let isDangling =
                    isRuntimeLease
                    || Self.isDockerDanglingReference(reference)

                if let danglingFilters = filters["dangling"] {
                    if let danglingValue = danglingFilters.first {
                        let shouldBeDangling = MobyBool.parse(danglingValue) ?? false
                        if shouldBeDangling {
                            shouldDelete = isDangling
                        } else {
                            shouldDelete = true
                        }
                    }
                } else {
                    shouldDelete = isDangling
                }

                var imageConfig: ContainerizationOCI.Image?
                let requiresConfig =
                    filters["label"] != nil || filters["until"] != nil
                if shouldDelete && requiresConfig {
                    let descriptors =
                        try await runnableImageSelector
                        .descriptors(for: image)
                    imageConfig =
                        runnableImageSelector.selectVariant(
                            from: descriptors,
                            requestedPlatform: nil
                        )?.config
                    shouldDelete = Self.pruneCandidateHasRequiredConfig(
                        shouldDelete,
                        requiresConfig: true,
                        hasRunnableConfig: imageConfig != nil
                    )
                    if !shouldDelete {
                        logger.warning(
                            "Skipping config-filtered prune of \(reference): no runnable image config is available"
                        )
                    }
                }

                if shouldDelete, let labelFilters = filters["label"], let config = imageConfig {
                    var allLabelsMatch = true
                    for labelFilter in labelFilters {
                        if let eqIdx = labelFilter.firstIndex(of: "=") {
                            let key = String(labelFilter[..<eqIdx])
                            let value = String(labelFilter[labelFilter.index(after: eqIdx)...])
                            if config.config?.labels?[key] != value {
                                allLabelsMatch = false
                                break
                            }
                        } else {
                            if config.config?.labels?[labelFilter] == nil {
                                allLabelsMatch = false
                                break
                            }
                        }
                    }

                    shouldDelete = shouldDelete && allLabelsMatch
                }

                if shouldDelete, let untilFilters = filters["until"], let config = imageConfig {
                    let createdIso8601 = config.created ?? "1970-01-01T00:00:00Z"

                    let iso8601Formatter = ISO8601DateFormatter()
                    iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    var imageCreationDate = iso8601Formatter.date(from: createdIso8601)

                    if imageCreationDate == nil {
                        iso8601Formatter.formatOptions = [.withInternetDateTime]
                        imageCreationDate = iso8601Formatter.date(from: createdIso8601)
                    }

                    if let imageCreationDate = imageCreationDate {
                        var matchesUntil = false

                        for untilValue in untilFilters {
                            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                            var untilDate = iso8601Formatter.date(from: untilValue)

                            if untilDate == nil {
                                iso8601Formatter.formatOptions = [.withInternetDateTime]
                                untilDate = iso8601Formatter.date(from: untilValue)
                            }

                            if untilDate == nil {
                                if let unixTimestamp = TimeInterval(untilValue) {
                                    untilDate = Date(timeIntervalSince1970: unixTimestamp)
                                }
                            }

                            if let untilDate = untilDate {
                                if imageCreationDate < untilDate {
                                    matchesUntil = true
                                    break
                                }
                            } else {
                                logger.warning("Failed to parse until timestamp: \(untilValue)")
                            }
                        }

                        shouldDelete = shouldDelete && matchesUntil
                    } else {
                        logger.warning("Failed to parse image creation date: \(createdIso8601)")
                        shouldDelete = false
                    }
                }

            } catch {
                logger.warning("Failed to get details for image \(image.reference): \(error)")
                continue
            }

            if shouldDelete {
                imagesToDelete.append(image)
            }
        }

        var results: [ImageDeletionResult] = []
        var spaceReclaimed: Int64 = 0

        for image in imagesToDelete {
            do {
                let reference = image.reference

                // Capture the per-image untag/delete result so the route can emit moby-faithful
                // per-image events. moby's image prune emits an `untag` per removed reference and
                // a `delete` per freed digest — never an aggregate "prune" event.
                let result: ImageDeletionResult
                if Self.isPrunableInternalDanglingReference(reference)
                    || ContainerImageLease.isReference(reference)
                {
                    result = try await deleteExactPhysicalImageDuringMutation(
                        image
                    )
                } else {
                    let current =
                        try await identityResolver
                        .resolveDuringMutation(reference)
                    guard current.image.digest == image.digest else {
                        logger.info(
                            "Skipping prune of \(reference): tag moved from \(image.digest) to \(current.image.digest)"
                        )
                        continue
                    }
                    result = try await deleteDuringMutation(
                        id: reference,
                        force: false
                    )
                }
                await identityResolver.invalidate()
                results.append(result)
                spaceReclaimed += result.reclaimedBytes
            } catch {
                logger.warning("Failed to delete image \(image.reference): \(error)")
            }
        }

        return (results, spaceReclaimed)
    }

    static func pruneCandidateHasRequiredConfig(
        _ selected: Bool,
        requiresConfig: Bool,
        hasRunnableConfig: Bool
    ) -> Bool {
        selected && (!requiresConfig || hasRunnableConfig)
    }

    static func isDockerDanglingReference(_ reference: String) -> Bool {
        ContainerImageLease.isReference(reference)
            || isPrunableInternalDanglingReference(reference)
    }

    private static func isPrunableInternalDanglingReference(
        _ reference: String
    ) -> Bool {
        reference.hasPrefix("moby-dangling@sha256:")
            || reference.hasPrefix("untagged@sha256:")
            || reference.hasPrefix("<none>")
    }

    func load(tarballPath: URL, platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] {
        try await loadWithIdentities(
            tarballPath: tarballPath,
            platform: platform,
            appleContainerAppSupportUrl: appleContainerAppSupportUrl,
            logger: logger
        ).references
    }

    func loadWithIdentities(
        tarballPath: URL,
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> LoadedImageArchive {
        let tempDir =
            try RequestBodyFileWriter
            .createSecureTemporaryDirectory()

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let extractedPath = tempDir.appendingPathComponent("extracted")
        try ArchiveUtility.extract(
            tarPath: tarballPath,
            to: extractedPath,
            limits: .imageLoad,
            transactional: true
        )

        // `docker buildx build --load`, the containerd "docker" exporter, and
        // `docker save` on modern Docker emit a tarball that is already a valid
        // OCI image layout (an `oci-layout` marker, an `index.json`, and blobs
        // under `blobs/sha256/`). Such tarballs also include a legacy
        // `manifest.json` for backwards compatibility, but its `Config`/`Layers`
        // entries point at `blobs/sha256/<digest>` rather than the legacy
        // `<digest>.json` / `<digest>/layer.tar` paths, so the docker-archive
        // converter cannot consume them. Load the OCI layout directly and only
        // fall back to conversion for genuinely legacy docker-archive tarballs.
        let ociLayoutPath: URL
        let hasOCILayout =
            FileManager.default.fileExists(atPath: extractedPath.appendingPathComponent("oci-layout").path)
            && FileManager.default.fileExists(atPath: extractedPath.appendingPathComponent("index.json").path)

        if hasOCILayout {
            ociLayoutPath = extractedPath
            try OCILayoutPruner.pruneManifestsWithMissingBlobs(
                at: ociLayoutPath,
                platform: platform,
                logger: logger
            )
        } else {
            ociLayoutPath = tempDir.appendingPathComponent("oci-layout")
            try FileManager.default.createDirectory(at: ociLayoutPath, withIntermediateDirectories: true)
            _ = try await ContainerImageUtility.convertDockerTarToOCI(
                dockerFormatPath: extractedPath,
                ociLayoutPath: ociLayoutPath,
                logger: logger
            )
        }

        // Apple's ImageStore.load imports every index.json descriptor inside ONE
        // ingest session; descriptors sharing a blob (multi-tag saves, images on a
        // common base layer) then collide with "File exists" in the ingest dir.
        // Loading one descriptor at a time gives each import a fresh session.
        let indexURL = ociLayoutPath.appendingPathComponent("index.json")
        let index = try JSONDecoder().decode(
            Index.self,
            from: BoundedFileReader.readImageMetadata(
                relativePath: "index.json",
                under: ociLayoutPath
            )
        )
        var descriptors = index.manifests

        guard !descriptors.isEmpty else {
            throw OCILayoutPruner.PruneError.nothingLoadable
        }

        // Canonicalize every top-level name before Apple registers it. A valid
        // OCI archive may expose one tag on several platform manifests (plus
        // BuildKit attestations); fold that coherent set into one index root.
        // Two descriptors competing for the same platform remain a conflict.
        let canonicalized = try canonicalLoadDescriptors(
            descriptors,
            in: ociLayoutPath
        )
        descriptors = canonicalized.descriptors
        let descriptorTargets = canonicalized.targets
        let targetReferences = descriptorTargets.compactMap { $0 }

        let canonicalDescriptors = descriptors
        let canonicalDescriptorTargets = descriptorTargets
        let baseIndex = index
        let loadedArchive = try await replacingImages(
            targeting: targetReferences,
            operation: {
                var assignments: [CanonicalImageAssignment] = []
                var loadedReferences: [String] = []
                for (offset, descriptor) in canonicalDescriptors.enumerated() {
                    var descriptorIndex = baseIndex
                    descriptorIndex.manifests = [descriptor]
                    try JSONEncoder().encode(descriptorIndex).write(to: indexURL, options: .atomic)
                    let descriptorArchive = tempDir.appendingPathComponent("descriptor-\(offset).tar")
                    let result: ImageArchiveLoadResult
                    do {
                        try ArchiveUtility.create(
                            tarPath: descriptorArchive,
                            from: ociLayoutPath
                        )
                        // A multi-tag archive is imported one descriptor at a time
                        // because Apple's ingest session cannot accept shared blobs
                        // twice. Retain only the archive currently crossing the XPC
                        // boundary; otherwise N descriptors accumulate N complete
                        // copies of the OCI layout until the entire load returns.
                        defer {
                            try? FileManager.default.removeItem(
                                at: descriptorArchive
                            )
                        }
                        result = try await archiveLoader.load(
                            ociLayoutPath: ociLayoutPath,
                            archivePath: descriptorArchive
                        )
                    }
                    guard result.rejectedMembers.isEmpty else {
                        throw ArchiveUtilityError.rejectedArchiveEntries(result.rejectedMembers)
                    }
                    guard let primaryImage = result.images.first else {
                        throw ClientImageError.notFound(
                            id: canonicalDescriptorTargets[offset] ?? descriptor.digest
                        )
                    }
                    if let target = canonicalDescriptorTargets[offset] {
                        assignments.append(
                            CanonicalImageAssignment(
                                targetReference: target,
                                image: primaryImage
                            )
                        )
                        loadedReferences.append(target)
                    } else {
                        loadedReferences.append(contentsOf: result.images.map(\.reference))
                    }
                }

                return ImageReplacementOutcome(
                    value: LoadedImageArchive(
                        references: loadedReferences,
                        actorIDs: []
                    ),
                    assignments: assignments
                )
            },
            afterCommit: { [identityResolver] archive in
                var actorIDs: [String] = []
                for reference in archive.references {
                    actorIDs.append(
                        (try? await identityResolver.resolveDuringMutation(
                            reference
                        ).dockerConfigDigest) ?? reference
                    )
                }
                return LoadedImageArchive(
                    references: archive.references,
                    actorIDs: actorIDs
                )
            })
        for image in loadedArchive.references {
            logger.info("Loaded image: \(image)")
        }

        logger.info("Successfully loaded \(loadedArchive.references.count) image(s) from tarball")
        return loadedArchive
    }

    private static func reference(from descriptor: Descriptor) -> String {
        let annotations = descriptor.annotations ?? [:]
        return annotations[AnnotationKeys.containerizationImageName]
            ?? annotations[AnnotationKeys.containerdImageName]
            ?? annotations[AnnotationKeys.openContainersImageName]
            ?? "untagged@\(descriptor.digest)"
    }

    private static func setImageReference(_ reference: String, on descriptor: inout Descriptor) {
        var annotations = descriptor.annotations ?? [:]
        annotations[AnnotationKeys.containerizationImageName] = reference
        annotations[AnnotationKeys.containerdImageName] = reference
        annotations[AnnotationKeys.openContainersImageName] = reference
        descriptor.annotations = annotations
    }

    private func canonicalLoadDescriptors(
        _ descriptors: [Descriptor],
        in ociLayoutPath: URL
    ) throws -> (descriptors: [Descriptor], targets: [String?]) {
        var groups: [String: [Descriptor]] = [:]
        for descriptor in descriptors {
            let original = Self.reference(from: descriptor)
            guard let canonical = referenceManager.canonicalTag(original) else {
                continue
            }
            groups[canonical, default: []].append(descriptor)
        }

        var emittedTargets: Set<String> = []
        var canonicalDescriptors: [Descriptor] = []
        var targets: [String?] = []
        for descriptor in descriptors {
            let original = Self.reference(from: descriptor)
            guard let canonical = referenceManager.canonicalTag(original) else {
                if try OCILayoutPruner.containsCoherentRunnableImage(
                    for: descriptor,
                    in: ociLayoutPath
                ) {
                    canonicalDescriptors.append(descriptor)
                    targets.append(nil)
                }
                continue
            }
            guard emittedTargets.insert(canonical).inserted,
                let grouped = groups[canonical]
            else {
                continue
            }

            var descriptorsByDigest: [String: [Descriptor]] = [:]
            var unique: [Descriptor] = []
            for member in grouped {
                let memberArtifact = try OCILayoutPruner.artifactMetadata(
                    for: member,
                    in: ociLayoutPath
                )
                if let existing = descriptorsByDigest[member.digest] {
                    let existingArtifacts = try existing.map {
                        try OCILayoutPruner.artifactMetadata(
                            for: $0,
                            in: ociLayoutPath
                        )
                    }
                    if zip(existing, existingArtifacts).contains(where: {
                        Self.sameLoadSemantics(
                            $0.0,
                            member,
                            leftArtifact: $0.1,
                            rightArtifact: memberArtifact
                        )
                    }) {
                        continue
                    }
                    // OCI descriptors may reuse one artifact manifest for
                    // multiple subjects by carrying the subject association in
                    // descriptor annotations. Those are distinct attestations,
                    // not competing image roots. Runnable descriptors sharing a
                    // digest but claiming different platforms remain invalid.
                    guard memberArtifact.isArtifact,
                        existingArtifacts.allSatisfy(\.isArtifact)
                    else {
                        throw ClientImageError.conflict(
                            "conflict: archive contains multiple images for tag \(canonical)"
                        )
                    }
                }
                descriptorsByDigest[member.digest, default: []].append(member)
                unique.append(member)
            }
            var canonicalDescriptor: Descriptor
            if unique.count == 1, let only = unique.first {
                canonicalDescriptor = only
            } else {
                canonicalDescriptor = try Self.synthesizedIndexDescriptor(
                    for: unique,
                    target: canonical,
                    in: ociLayoutPath
                )
            }
            guard
                try OCILayoutPruner.containsCoherentRunnableImage(
                    for: canonicalDescriptor,
                    in: ociLayoutPath
                )
            else {
                throw ClientImageError.conflict(
                    "conflict: archive contains no coherent runnable image for tag \(canonical)"
                )
            }
            Self.setImageReference(canonical, on: &canonicalDescriptor)
            canonicalDescriptors.append(canonicalDescriptor)
            targets.append(canonical)
        }
        guard !canonicalDescriptors.isEmpty else {
            throw ClientImageError.conflict(
                "conflict: archive contains no coherent runnable image"
            )
        }
        return (canonicalDescriptors, targets)
    }

    private static func synthesizedIndexDescriptor(
        for descriptors: [Descriptor],
        target: String,
        in ociLayoutPath: URL
    ) throws -> Descriptor {
        let manifestsOnly = descriptors.allSatisfy {
            $0.mediaType == MediaTypes.imageManifest
                || $0.mediaType == MediaTypes.dockerManifest
        }
        let described = try descriptors.map {
            (
                descriptor: $0,
                artifact: try OCILayoutPruner.artifactMetadata(
                    for: $0,
                    in: ociLayoutPath
                )
            )
        }
        let runnable = described.filter { !$0.artifact.isArtifact }
        let attestations = described.filter(\.artifact.isArtifact)
        var platforms: Set<Platform> = []
        let coherentRunnableSet = runnable.allSatisfy { described in
            guard let platform = described.descriptor.platform else {
                return false
            }
            return platforms.insert(platform).inserted
        }
        let runnableDigests = Set(runnable.map(\.descriptor.digest))
        let coherentAttestations = attestations.allSatisfy { described in
            guard let subject = described.artifact.subjectDigest else {
                return false
            }
            return runnableDigests.contains(subject)
        }
        guard manifestsOnly,
            !runnable.isEmpty,
            coherentRunnableSet,
            coherentAttestations
        else {
            throw ClientImageError.conflict(
                "conflict: archive contains multiple images for tag \(target)"
            )
        }

        // Apple's platform lookup returns the first descriptor with a matching
        // platform and does not exclude OCI artifacts. Canonical roots loaded
        // through Glass Dock therefore keep runnable manifests before their
        // attestations, with stable ordering inside both groups. Reporting and
        // identity still use exact digests and never rely on this order.
        let canonicalMembers =
            runnable.map(\.descriptor).sorted(
                by: Self.stableLoadDescriptorOrder
            )
            + attestations.map(\.descriptor).sorted(
                by: Self.stableLoadDescriptorOrder
            )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Index(manifests: canonicalMembers))
        let digest = "sha256:" + data.sha256Hex()
        let blobURL =
            ociLayoutPath
            .appendingPathComponent("blobs/sha256")
            .appendingPathComponent(String(digest.dropFirst("sha256:".count)))
        try data.write(to: blobURL, options: .atomic)
        return Descriptor(
            mediaType: MediaTypes.index,
            digest: digest,
            size: Int64(data.count)
        )
    }

    private static func sameLoadSemantics(
        _ left: Descriptor,
        _ right: Descriptor,
        leftArtifact: OCILayoutPruner.ArtifactMetadata,
        rightArtifact: OCILayoutPruner.ArtifactMetadata
    ) -> Bool {
        left.mediaType == right.mediaType
            && left.platform == right.platform
            && left.artifactType == right.artifactType
            && left.annotations?["vnd.docker.reference.type"]
                == right.annotations?["vnd.docker.reference.type"]
            && left.annotations?["vnd.docker.reference.digest"]
                == right.annotations?["vnd.docker.reference.digest"]
            && leftArtifact == rightArtifact
    }

    private static func stableLoadDescriptorOrder(
        _ left: Descriptor,
        _ right: Descriptor
    ) -> Bool {
        let leftPlatform = left.platform?.description ?? ""
        let rightPlatform = right.platform?.description ?? ""
        if leftPlatform != rightPlatform {
            return leftPlatform < rightPlatform
        }
        let leftSubject =
            left.annotations?["vnd.docker.reference.digest"] ?? ""
        let rightSubject =
            right.annotations?["vnd.docker.reference.digest"] ?? ""
        if leftSubject != rightSubject {
            return leftSubject < rightSubject
        }
        return left.digest < right.digest
    }

    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        try await saveWithIdentities(
            references: references,
            platform: platform,
            appleContainerAppSupportUrl: appleContainerAppSupportUrl,
            logger: logger
        ).url
    }

    func saveWithIdentities(
        references: [String],
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> SavedImageArchive {
        try await mutationCoordinator.withMutationExcluded { [self] in
            var resolvedReferences: [String] = []
            var constraints: [RunnableImageIdentityConstraint] = []
            var actorIDs: [String] = []

            for reference in references {
                do {
                    let resolved = try await identityResolver.resolve(reference)
                    if let platform, let implied = resolved.impliedPlatform,
                        implied != platform
                    {
                        throw ClientImageError.conflict(
                            "conflict: image \(reference) selects \(implied.description), not requested platform \(platform.description)"
                        )
                    }
                    logger.debug("Image exists: \(resolved.reference)")
                    resolvedReferences.append(resolved.reference)
                    constraints.append(resolved.variantConstraint)
                    actorIDs.append(resolved.dockerConfigDigest)
                } catch let error as ImageIdentityResolutionError {
                    logger.error("Image not found: \(reference)")
                    if case .ambiguous = error {
                        throw ClientImageError.conflict(
                            "conflict: \(reference) is an ambiguous image ID"
                        )
                    }
                    throw ClientImageError.notFound(id: reference)
                }
            }

            let url = try await exportTarball(
                resolvedReferences: resolvedReferences,
                platform: platform,
                constraints: constraints,
                appleContainerAppSupportUrl: appleContainerAppSupportUrl,
                logger: logger
            )
            return SavedImageArchive(url: url, actorIDs: actorIDs)
        }
    }

    func exportTarball(
        resolvedReferences: [String],
        platform: Platform?,
        constraints: [RunnableImageIdentityConstraint]? = nil,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> URL {
        let imageStore = try ImageStore(path: appleContainerAppSupportUrl)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var handedOffToResponse = false
        defer {
            if !handedOffToResponse {
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let exportPath = tempDir.appendingPathComponent("oci-layout")
        try FileManager.default.createDirectory(at: exportPath, withIntermediateDirectories: true)

        do {
            try await imageStore.save(
                references: resolvedReferences,
                out: exportPath,
                platform: constraints == nil ? platform : nil
            )
            if let constraints {
                try OCILayoutPruner.selectExactIdentities(
                    at: exportPath,
                    constraints: constraints,
                    platform: platform,
                    logger: logger
                )
            }
        } catch {
            let errorDescription = String(describing: error)
            logger.error("Failed to export images: \(errorDescription)")

            if errorDescription.contains("notFound") && errorDescription.localizedCaseInsensitiveContains("content with digest") {
                let detailedMessage =
                    "Export failed: ContentStore missing blob data. This is a limitation of Apple's Containerization framework. The image metadata exists but the underlying content blobs are not available."
                logger.error("\(detailedMessage)")
                throw ClientImageError.notFound(id: detailedMessage)
            }
            throw error
        }

        let dockerFormatPath = tempDir.appendingPathComponent("docker-format")
        try FileManager.default.createDirectory(at: dockerFormatPath, withIntermediateDirectories: true)

        let dockerManifests = try await ContainerImageUtility.convertOCIToDockerTar(
            ociLayoutPath: exportPath,
            dockerFormatPath: dockerFormatPath,
            resolvedRefs: resolvedReferences,
            logger: logger
        )

        let dockerManifestData = try JSONSerialization.data(withJSONObject: dockerManifests, options: [.prettyPrinted])
        try dockerManifestData.write(to: dockerFormatPath.appendingPathComponent("manifest.json"))

        let tarballPath = tempDir.appendingPathComponent("images.tar")

        try ArchiveUtility.create(tarPath: tarballPath, from: dockerFormatPath)

        logger.info("Successfully exported \(resolvedReferences.count) image(s) to tarball in Docker format")

        handedOffToResponse = true
        return tarballPath
    }

    /// `docker import`: synthesizes a single-layer OCI image from `tarPath` (the
    /// raw `fromSrc=-` request body) and loads it into the image store the same
    /// way `load()` does. Returns the registered reference (nil if untagged) and
    /// the OCI config digest Docker exposes as the local image ID. Apple's
    /// internal index/root digest remains an implementation detail.
    func importImage(
        tarPath: URL,
        repo: String?,
        tag: String?,
        message: String?,
        changes: [String],
        platform: Platform,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> (reference: String?, digest: String) {
        let reference = try resolveImportReference(repo: repo, tag: tag)

        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(changes, to: &config)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ociLayoutPath = tempDir.appendingPathComponent("oci-layout")
        try FileManager.default.createDirectory(at: ociLayoutPath, withIntermediateDirectories: true)

        let synthesizedIdentity = try ContainerImageUtility.buildSingleLayerOCILayout(
            tarPath: tarPath,
            ociLayoutPath: ociLayoutPath,
            platform: platform,
            config: config,
            message: message,
            reference: reference,
            logger: logger
        )

        let archivePath = tempDir.appendingPathComponent("import-image.tar")
        try ArchiveUtility.create(tarPath: archivePath, from: ociLayoutPath)
        let image = try await replacingImages(targeting: reference.map { [$0] } ?? []) {
            let result = try await archiveLoader.load(
                ociLayoutPath: ociLayoutPath,
                archivePath: archivePath
            )
            guard result.rejectedMembers.isEmpty else {
                throw ArchiveUtilityError.rejectedArchiveEntries(result.rejectedMembers)
            }
            guard let image = result.images.first else {
                throw ClientImageError.notFound(id: reference ?? "imported image")
            }
            return ImageReplacementOutcome(
                value: image,
                assignments: reference.map {
                    [CanonicalImageAssignment(targetReference: $0, image: image)]
                } ?? []
            )
        }

        logger.info("Imported image \(image.reference) (\(image.digest))")
        return (
            reference,
            "sha256:\(synthesizedIdentity.configDigest)"
        )
    }

    /// Mirrors moby's `httputils.RepoTagReference`: empty repo means an
    /// untagged import; an empty tag defaults to "latest" (via
    /// `normalizeReference`'s `.normalize()`); a digest reference is rejected —
    /// `docker import` produces a new image, it cannot target an existing digest.
    private func resolveImportReference(repo: String?, tag: String?) throws -> String? {
        guard let repo, !repo.isEmpty else { return nil }
        if case .digestNotAllowed = Self.validateImportReference(repo: repo, tag: tag ?? "") {
            throw ClientImageError.digestReferenceNotAllowed(repo: repo)
        }
        let raw = (tag?.isEmpty == false) ? "\(repo):\(tag!)" : repo
        return try ClientImage.normalizeReference(raw, containerSystemConfig: containerSystemConfig)
    }

    enum ImportReferenceValidation: Equatable {
        case valid
        case digestNotAllowed
        case malformed(reason: String)
    }

    /// Mirrors moby's early `httputils.RepoTagReference` validation
    /// (api/server/router/image/image_routes.go's `postImagesCreate` validates
    /// before the layer reader is even constructed): parses `repo`/`tag`
    /// through the same reference grammar `normalizeReference` uses, so any
    /// malformed reference — not just a digest — is rejected before the
    /// request body is read, and both callers of this check (the route's
    /// fail-fast and this file's own `resolveImportReference`) agree.
    static func validateImportReference(repo: String, tag: String) -> ImportReferenceValidation {
        guard !repo.isEmpty else { return .valid }
        let raw = tag.isEmpty ? repo : "\(repo):\(tag)"
        do {
            let parsed = try Reference.parse(raw)
            return parsed.digest != nil ? .digestNotAllowed : .valid
        } catch {
            return .malformed(reason: String(describing: error))
        }
    }
}
