import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation

protocol ImageReferenceStore: Sendable {
    func list() async throws -> [ClientImage]
    func tag(existing: String, new: String) async throws -> ClientImage
    func delete(reference: String) async throws
    func cleanUpOrphanedBlobs() async throws -> UInt64
}

struct LiveImageReferenceStore: ImageReferenceStore {
    func list() async throws -> [ClientImage] {
        try await ClientImage.list()
    }

    func tag(existing: String, new: String) async throws -> ClientImage {
        guard let image = try await ClientImage.list().first(where: { $0.reference == existing }) else {
            throw ContainerizationError(.notFound, message: "image \(existing) not found")
        }
        return try await image.tag(new: new)
    }

    func delete(reference: String) async throws {
        try await ClientImage.delete(reference: reference, garbageCollect: false)
    }

    func cleanUpOrphanedBlobs() async throws -> UInt64 {
        let (_, freed) = try await ClientImage.cleanUpOrphanedBlobs()
        return freed
    }
}

struct CanonicalImageAssignment: Sendable {
    let targetReference: String
    let image: ClientImage
    let variantConstraint: RunnableImageIdentityConstraint

    init(
        targetReference: String,
        image: ClientImage,
        variantConstraint: RunnableImageIdentityConstraint = .unconstrained
    ) {
        self.targetReference = targetReference
        self.image = image
        self.variantConstraint = variantConstraint
    }
}

struct PreparedImageReplacement: Sendable {
    fileprivate struct OriginalReference: Sendable {
        let reference: String
        let digest: String
    }

    fileprivate var targets: Set<String> = []
    fileprivate var exactRepositoryDigestTargets: Set<String> = []
    fileprivate var initialRootsByReference: [String: Set<String>] = [:]
    fileprivate var originalReferences: [OriginalReference] = []
    fileprivate var preservedReferencesByDigest: [String: String] = [:]
}

enum CanonicalImageReferenceError: Error, Equatable {
    case replacementMissing(target: String, digest: String)
    case assignmentMissing(target: String)
    case conflictingAssignments(target: String)
}

/// Implements moby's single-owner tag semantics on top of Apple's exact-key
/// reference map.
///
/// Apple legitimately treats `example:latest` and
/// `docker.io/library/example:latest` as different keys. Docker does not. Before
/// an operation can replace a tag, the old root is retained under a digest-only
/// dangling reference when it would otherwise lose its final name. After the
/// operation, the new root is installed at the normalized key and every familiar
/// spelling of that tag is removed. Digest-prefix ambiguity remains untouched.
struct CanonicalImageReferenceManager: Sendable {
    private let systemConfig: ContainerSystemConfig
    private let store: any ImageReferenceStore

    init(
        systemConfig: ContainerSystemConfig,
        store: any ImageReferenceStore = LiveImageReferenceStore()
    ) {
        self.systemConfig = systemConfig
        self.store = store
    }

    func prepareToReplace(_ references: [String]) async throws -> PreparedImageReplacement {
        try await prepare(references, excludingPreservationForDigest: nil)
    }

    /// Adds immutable distribution associations discovered by an operation
    /// after its OCI root has been resolved (notably a tag pull). Recording the
    /// pre-existing exact keys makes their installation part of the same
    /// rollback boundary as mutable tag ownership.
    func prepareRepositoryDigestAssignments(
        _ assignments: [CanonicalImageAssignment],
        prepared: PreparedImageReplacement
    ) async throws -> PreparedImageReplacement {
        let targets = Set(
            assignments.compactMap { assignment in
                repositoryDigest(assignment.targetReference)
            }
        )
        guard !targets.isEmpty else { return prepared }

        var updated = prepared
        updated.exactRepositoryDigestTargets.formUnion(targets)
        let recorded = Set(updated.originalReferences.map(\.reference))
        updated.originalReferences.append(
            contentsOf: try targets.sorted().compactMap { target in
                guard !recorded.contains(target),
                    let roots = prepared.initialRootsByReference[target]
                else { return nil }
                guard roots.count == 1, let digest = roots.first else {
                    throw CanonicalImageReferenceError.conflictingAssignments(
                        target: target
                    )
                }
                return PreparedImageReplacement.OriginalReference(
                    reference: target,
                    digest: digest
                )
            }
        )
        return updated
    }

    /// Retires one logical tag while retaining only roots that had already been
    /// displaced by another authoritative owner. The selected owner is being
    /// explicitly deleted and must not be converted into a dangling image.
    func prepareToRemove(
        _ reference: String,
        currentOwnerDigest: String
    ) async throws -> PreparedImageReplacement {
        try await prepare(
            [reference],
            excludingPreservationForDigest: currentOwnerDigest
        )
    }

    private func prepare(
        _ references: [String],
        excludingPreservationForDigest excludedDigest: String?
    ) async throws -> PreparedImageReplacement {
        let targets = Set(references.compactMap(canonicalTag))
        let exactRepositoryDigestTargets = Set(
            references.compactMap(repositoryDigest)
        )
        let images = try await store.list()
        let initialRootsByReference = Self.rootsByReference(images)
        for target in exactRepositoryDigestTargets {
            if let roots = initialRootsByReference[target], roots.count != 1 {
                throw CanonicalImageReferenceError.conflictingAssignments(
                    target: target
                )
            }
        }
        let owners = images.filter { image in
            !claimedTags(for: image).isDisjoint(with: targets)
                || exactRepositoryDigestTargets.contains(image.reference)
        }
        let byDigest = Dictionary(grouping: owners, by: \.digest)
        var prepared = PreparedImageReplacement(
            targets: targets,
            exactRepositoryDigestTargets: exactRepositoryDigestTargets,
            initialRootsByReference: initialRootsByReference,
            originalReferences: owners.map {
                PreparedImageReplacement.OriginalReference(
                    reference: $0.reference,
                    digest: $0.digest
                )
            }
        )

        do {
            for digest in byDigest.keys.sorted() {
                guard let matchingOwners = byDigest[digest] else { continue }
                let dangling = Self.danglingReference(for: digest)
                if digest == excludedDigest {
                    // A marker left by an interrupted earlier replacement is
                    // redundant while the current owner still has this real tag.
                    // Retire it before explicit deletion so it cannot keep the
                    // deliberately removed image alive.
                    if images.contains(where: {
                        $0.reference == dangling && $0.digest == digest
                    }) {
                        try await store.delete(reference: dangling)
                    }
                    continue
                }
                let otherRealReferences = images.contains { image in
                    image.digest == digest
                        && !Self.isDanglingReference(image.reference)
                        && !(canonicalTag(image.reference).map(targets.contains)
                            ?? false)
                        && !exactRepositoryDigestTargets.contains(
                            image.reference
                        )
                }
                guard !otherRealReferences else { continue }

                if images.contains(where: {
                    $0.reference == dangling && $0.digest == digest
                }) {
                    prepared.preservedReferencesByDigest[digest] = dangling
                    continue
                }
                guard
                    let representative = matchingOwners.sorted(by: {
                        $0.reference < $1.reference
                    }).first
                else {
                    continue
                }
                // Record the intended marker before crossing the XPC boundary.
                // Apple's image service can commit a tag and then report an
                // interruption to the client. Rollback must therefore attempt
                // to remove this exact marker even when `tag` throws.
                prepared.preservedReferencesByDigest[digest] = dangling
                _ = try await store.tag(
                    existing: representative.reference,
                    new: dangling
                )
            }
            return prepared
        } catch {
            await rollbackUncancelled(prepared)
            throw error
        }
    }

    func commit(
        _ assignments: [CanonicalImageAssignment],
        prepared: PreparedImageReplacement
    ) async throws {
        var assignmentsByTarget: [String: CanonicalImageAssignment] = [:]
        for assignment in assignments {
            guard let target = canonicalTag(assignment.targetReference) else { continue }
            if let existing = assignmentsByTarget[target], existing.image.digest != assignment.image.digest {
                throw CanonicalImageReferenceError.conflictingAssignments(target: target)
            }
            assignmentsByTarget[target] = assignment
        }
        for target in prepared.targets where assignmentsByTarget[target] == nil {
            throw CanonicalImageReferenceError.assignmentMissing(target: target)
        }

        var digestAssignments: [String: CanonicalImageAssignment] = [:]
        for assignment in assignments {
            guard let target = repositoryDigest(assignment.targetReference)
            else { continue }
            if let existing = digestAssignments[target],
                existing.image.digest != assignment.image.digest
            {
                throw CanonicalImageReferenceError.conflictingAssignments(
                    target: target
                )
            }
            digestAssignments[target] = assignment
        }
        for target in prepared.exactRepositoryDigestTargets
        where digestAssignments[target] == nil {
            throw CanonicalImageReferenceError.assignmentMissing(target: target)
        }

        for target in assignmentsByTarget.keys.sorted() {
            guard let assignment = assignmentsByTarget[target] else { continue }
            if assignment.image.reference != target {
                _ = try await store.tag(existing: assignment.image.reference, new: target)
            }

            // Remove every exact Apple key that denotes the same Docker tag.
            // The normalized target is the sole surviving owner.
            let aliases = try await store.list().filter { image in
                image.reference != target && claimedTags(for: image).contains(target)
            }
            for alias in aliases.sorted(by: { $0.reference < $1.reference }) {
                try await store.delete(reference: alias.reference)
            }

            let finalOwner = try await store.list().first(where: { $0.reference == target })
            guard finalOwner?.digest == assignment.image.digest else {
                throw CanonicalImageReferenceError.replacementMissing(
                    target: target,
                    digest: assignment.image.digest
                )
            }
        }

        for target in digestAssignments.keys.sorted() {
            guard let assignment = digestAssignments[target] else { continue }
            if let initialRoots = prepared.initialRootsByReference[target],
                !initialRoots.allSatisfy({
                    $0 == assignment.image.digest
                })
            {
                throw CanonicalImageReferenceError.conflictingAssignments(
                    target: target
                )
            }
            let existing = try await store.list().filter {
                $0.reference == target
            }
            if !existing.isEmpty {
                guard
                    existing.allSatisfy({
                        $0.digest == assignment.image.digest
                    })
                else {
                    throw CanonicalImageReferenceError.conflictingAssignments(
                        target: target
                    )
                }
            } else {
                _ = try await store.tag(
                    existing: assignment.image.reference,
                    new: target
                )
            }
            let finalAssociations = try await store.list().filter {
                $0.reference == target
            }
            guard !finalAssociations.isEmpty,
                finalAssociations.allSatisfy({
                    $0.digest == assignment.image.digest
                })
            else {
                throw CanonicalImageReferenceError.replacementMissing(
                    target: target,
                    digest: assignment.image.digest
                )
            }
        }

        try await removeRedundantPreservationReferences(prepared)
    }

    /// Best-effort transactional rollback. Pull and load can replace Apple's
    /// exact key before a later unpack or archive validation error is reported.
    /// Restore every original spelling first, remove a newly-created canonical
    /// key that did not previously exist, and only then retire redundant safety
    /// references. A failed operation therefore cannot silently retag an image.
    func rollback(_ prepared: PreparedImageReplacement) async {
        do {
            var images = try await store.list()
            for original in prepared.originalReferences.sorted(by: { $0.reference < $1.reference }) {
                if images.contains(where: {
                    $0.reference == original.reference && $0.digest == original.digest
                }) {
                    continue
                }
                guard let source = images.first(where: { $0.digest == original.digest }) else {
                    continue
                }
                _ = try await store.tag(existing: source.reference, new: original.reference)
                images = try await store.list()
            }

            let originalExactTargets = Set(
                prepared.originalReferences.compactMap { original in
                    prepared.targets.union(
                        prepared.exactRepositoryDigestTargets
                    ).contains(original.reference)
                        ? original.reference : nil
                }
            )
            let createdTargets = prepared.targets.union(
                prepared.exactRepositoryDigestTargets
            ).subtracting(originalExactTargets)
            for target in createdTargets.sorted() {
                if images.contains(where: { $0.reference == target }) {
                    try await store.delete(reference: target)
                    images = try await store.list()
                }
            }

            try await removeRedundantPreservationReferences(prepared)
        } catch {
            // Rollback is invoked while propagating the original operation error.
            // Its preservation references intentionally remain if restoration
            // cannot be completed, keeping the old content reachable by digest.
        }
    }

    /// Cleanup must not inherit request cancellation. The mutation coordinator
    /// still holds writer admission while this detached task is awaited, so the
    /// restored keys become visible atomically before another writer can begin.
    func rollbackUncancelled(_ prepared: PreparedImageReplacement) async {
        await Task.detached { [self] in
            await rollback(prepared)
        }.value
    }

    func canonicalTag(_ reference: String) -> String? {
        // Apple may retain content under a literal config/root digest key.
        // Distribution reference parsing interprets `sha256:<hex>` as the
        // repository `sha256` plus a tag, but Docker treats the full spelling
        // as an immutable image ID. Never publish or mutate it as tag ownership.
        guard !DockerImageReferenceSemantics.isBareSHA256Identifier(reference) else {
            return nil
        }
        guard let parsed = try? Reference.parse(reference), parsed.digest == nil else {
            return nil
        }
        guard
            let normalized = try? ClientImage.normalizeReference(
                reference,
                containerSystemConfig: systemConfig
            ), let normalizedReference = try? Reference.parse(normalized), normalizedReference.digest == nil
        else {
            return nil
        }
        return normalized
    }

    private func repositoryDigest(_ reference: String) -> String? {
        guard
            !DockerImageReferenceSemantics.isInternalReference(reference),
            !DockerImageReferenceSemantics.isBareSHA256Identifier(reference),
            let parsed = try? Reference.parse(reference),
            parsed.digest != nil
        else { return nil }
        return reference
    }

    private static func rootsByReference(
        _ images: [ClientImage]
    ) -> [String: Set<String>] {
        images.reduce(into: [:]) { result, image in
            result[image.reference, default: []].insert(image.digest)
        }
    }

    func physicalReferences(claiming reference: String) async throws -> [String] {
        guard let target = canonicalTag(reference) else { return [] }
        return try await store.list()
            .filter { claimedTags(for: $0).contains(target) }
            .map(\.reference)
            .sorted { left, right in
                // The authoritative exact key is the commit point for removal.
                // Delete stale/familiar spellings first so any intermediate
                // failure leaves the current owner selected.
                if left == target { return false }
                if right == target { return true }
                return left < right
            }
    }

    /// Exact Apple keys retaining one OCI root. This intentionally includes
    /// digest-only and internal dangling keys: they are physical retention,
    /// not additional Docker tags.
    func physicalReferences(forDigest digest: String) async throws -> [String] {
        try await store.list()
            .filter { $0.digest == digest }
            .map(\.reference)
            .sorted()
    }

    /// Returns only a physically stored exact key. Unlike Docker-visible image
    /// listing, this never synthesizes a canonical handle from a familiar alias.
    func exactImage(reference: String) async throws -> ClientImage? {
        try await store.list().first { $0.reference == reference }
    }

    /// Canonical Docker tag -> current Apple root, using the same exact-key
    /// precedence as resolver hydration. This is the commit witness for the
    /// durable exact-selector journal.
    func currentOwnerDigests() async throws -> [String: String] {
        let images = try await store.list()
        let claims = Dictionary(
            grouping: images.flatMap { image in
                claimedTags(for: image).map { ($0, image) }
            },
            by: { $0.0 }
        )
        var owners: [String: String] = [:]
        for (canonical, candidates) in claims {
            let exactRoots = Set(
                candidates.compactMap { _, image in
                    image.reference == canonical ? image.digest : nil
                }
            )
            if exactRoots.count == 1 {
                owners[canonical] = exactRoots.first
                continue
            }
            guard exactRoots.isEmpty else { continue }
            let roots = Set(candidates.map { $0.1.digest })
            if roots.count == 1 { owners[canonical] = roots.first }
        }
        return owners
    }

    func tagExact(sourceReference: String, targetReference: String) async throws -> ClientImage {
        try await store.tag(existing: sourceReference, new: targetReference)
    }

    /// Returns the logical Docker view without mutating Apple's physical store.
    /// This is also the crash-recovery view: an exact canonical key masks stale
    /// familiar keys until the next mutation retires them physically.
    func dockerVisibleImages(
        _ images: [ClientImage],
        activeLeaseRootDigests: Set<String> = []
    ) -> [ClientImage] {
        let claims = Dictionary(
            grouping: images.flatMap { image in
                claimedTags(for: image).map { ($0, image) }
            },
            by: { $0.0 }
        )
        var owners: [String: String] = [:]
        for (canonical, candidates) in claims {
            let exactRoots = Set(
                candidates.compactMap { _, image in
                    image.reference == canonical ? image.digest : nil
                })
            if exactRoots.count == 1 {
                owners[canonical] = exactRoots.first
            } else if exactRoots.isEmpty {
                let roots = Set(candidates.map { $0.1.digest })
                if roots.count == 1 { owners[canonical] = roots.first }
            }
        }

        var emitted: Set<String> = []
        var result: [ClientImage] = []
        for image in images.sorted(by: { $0.reference < $1.reference }) {
            let imageClaims = claimedTags(for: image)
            guard !imageClaims.isEmpty else {
                if !ContainerImageLease.isReference(image.reference) {
                    result.append(image)
                }
                continue
            }
            for canonical in imageClaims.sorted() {
                if let owner = owners[canonical], owner != image.digest { continue }
                let identity = "\(canonical)\u{0}\(image.digest)"
                guard emitted.insert(identity).inserted else { continue }
                result.append(
                    ClientImage(
                        description: ImageDescription(
                            reference: canonical,
                            descriptor: image.descriptor
                        )
                    )
                )
            }
        }

        // A stopped or running container can be the final owner of a root after
        // its last Docker tag is removed with force. Keep the hidden runtime key
        // private, but synthesize one anonymous Docker row so `image ls` still
        // attributes that root and its container count. If any ordinary or
        // dangling Docker row already represents the root, do not duplicate it.
        var representedRoots = Set(result.map(\.digest))
        for lease in images.sorted(by: { $0.reference < $1.reference })
        where ContainerImageLease.isReference(lease.reference)
            && activeLeaseRootDigests.contains(lease.digest)
            && representedRoots.insert(lease.digest).inserted
        {
            result.append(
                ClientImage(
                    description: ImageDescription(
                        reference: lease.digest,
                        descriptor: lease.descriptor
                    )
                )
            )
        }
        return result
    }

    /// A legacy Apple load may have stored an image under `untagged@<digest>`
    /// while leaving its requested name only in OCI annotations. Such a name is
    /// a valid fallback until a real reference exists. Once replaced, commit
    /// retires that exact legacy key and keeps the root under `moby-dangling`,
    /// whose historical annotations are never treated as ownership.
    private func claimedTags(for image: ClientImage) -> Set<String> {
        if let physicalTag = canonicalTag(image.reference) {
            return [physicalTag]
        }
        guard Self.isLegacyUntaggedReference(image.reference),
            let annotatedName = Self.annotationName(image),
            let annotatedTag = canonicalTag(annotatedName)
        else {
            return []
        }
        return [annotatedTag]
    }

    /// Match LocalOCILayoutClient's annotation precedence exactly. Lower
    /// priority annotations are metadata fallbacks, not independent tags.
    private static func annotationName(_ image: ClientImage) -> String? {
        let annotations = image.descriptor.annotations ?? [:]
        return annotations[AnnotationKeys.containerizationImageName]
            ?? annotations[AnnotationKeys.containerdImageName]
            ?? annotations[AnnotationKeys.openContainersImageName]
    }

    private func removeRedundantPreservationReferences(
        _ prepared: PreparedImageReplacement
    ) async throws {
        guard !prepared.preservedReferencesByDigest.isEmpty else { return }
        let images = try await store.list()
        for (digest, reference) in prepared.preservedReferencesByDigest {
            let hasRealReference = images.contains {
                $0.digest == digest && !Self.isDanglingReference($0.reference)
            }
            if hasRealReference,
                images.contains(where: { $0.reference == reference && $0.digest == digest })
            {
                try await store.delete(reference: reference)
            }
        }
    }

    private static func danglingReference(for digest: String) -> String {
        "moby-dangling@\(digest.hasPrefix("sha256:") ? digest : "sha256:\(digest)")"
    }

    private static func isDanglingReference(_ reference: String) -> Bool {
        DockerImageReferenceSemantics.isInternalReference(reference)
    }

    private static func isLegacyUntaggedReference(_ reference: String) -> Bool {
        reference.hasPrefix("untagged@sha256:") || reference.hasPrefix("<none>")
    }
}
