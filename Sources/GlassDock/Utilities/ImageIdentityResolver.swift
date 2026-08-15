import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation

/// The kinds of OCI content Docker clients may send back as an image identifier.
enum ImageIdentityKind: Sendable, Equatable {
    case reference
    case root
    case manifest(Platform)
    case config(Platform)
}

/// Immutable OCI scope selected by a Docker image identifier. Platform alone
/// is not an identity: one root can contain multiple runnable manifests for
/// the same platform, and a nested index denotes only its descendant subgraph.
enum RunnableImageIdentityConstraint: Sendable, Equatable, Hashable, Codable {
    case unconstrained
    case descendantOfIndex(String)
    case exactManifest(manifestDigest: String, configDigest: String)
}

struct ResolvedImageIdentity: Sendable {
    let image: ClientImage
    let reference: String
    /// Canonical Docker-visible tags for this root.
    let references: [String]
    /// Exact keys in Apple's reference store, including hidden dangling keys.
    let storeReferences: [String]
    /// Docker-visible immutable repository-scoped references.
    let repositoryDigests: [String]
    /// Exact Apple reference-store key selected by this lookup, when one
    /// exists. This is intentionally independent of `kind`: a physical
    /// `repository@manifest` key has manifest identity for create/inspect, but
    /// remains a named reference for untag/delete semantics.
    let selectedStoreReference: String?
    let kind: ImageIdentityKind
    let variantConstraint: RunnableImageIdentityConstraint
    /// Every Apple root that owns this immutable Docker identity. A reference
    /// lookup deliberately has one owner; a bare manifest/config digest can be
    /// reachable through several indexes without becoming ambiguous.
    let owners: [ResolvedImageOwner]
    /// Docker's local image ID is the selected OCI config digest, never Apple's
    /// index/root descriptor digest.
    let dockerConfigDigest: String

    init(
        image: ClientImage,
        reference: String,
        references: [String],
        storeReferences: [String],
        repositoryDigests: [String],
        selectedStoreReference: String?,
        kind: ImageIdentityKind,
        variantConstraint: RunnableImageIdentityConstraint,
        owners: [ResolvedImageOwner]? = nil,
        dockerConfigDigest: String? = nil
    ) {
        self.image = image
        self.reference = reference
        self.references = references
        self.storeReferences = storeReferences
        self.repositoryDigests = repositoryDigests
        self.selectedStoreReference = selectedStoreReference
        self.kind = kind
        self.variantConstraint = variantConstraint
        self.owners =
            owners ?? [
                ResolvedImageOwner(
                    image: image,
                    references: references,
                    storeReferences: storeReferences,
                    repositoryDigests: repositoryDigests
                )
            ]
        if let dockerConfigDigest {
            self.dockerConfigDigest = dockerConfigDigest
        } else if case .exactManifest(_, let configDigest) = variantConstraint {
            self.dockerConfigDigest = configDigest
        } else {
            // Compatibility default for narrow test seams. Production resolver
            // construction always supplies the selected runnable config digest.
            self.dockerConfigDigest = image.digest
        }
    }

    var impliedPlatform: Platform? {
        switch kind {
        case .manifest(let platform), .config(let platform): platform
        case .reference, .root: nil
        }
    }

    var rootDigests: Set<String> {
        Set(owners.map { $0.image.digest })
    }
}

struct ResolvedImageOwner: Sendable {
    let image: ClientImage
    let references: [String]
    let storeReferences: [String]
    let repositoryDigests: [String]
}

enum ImageIdentityResolutionError: Error, Equatable {
    case notFound(String)
    case ambiguous(String)
    case nonRunnable(String)
}

protocol ImageIdentityCatalog: OCIImageDocumentProviding {
    func list() async throws -> [ClientImage]
    func index(for image: ClientImage) async throws -> Index
}

struct ResolvedImageFilterIdentity: Sendable, Equatable {
    let rootDigests: Set<String>
    let references: [String]
    let dockerConfigDigest: String
    let wholeRoot: Bool

    init(
        rootDigests: Set<String>,
        references: [String],
        dockerConfigDigest: String = "",
        wholeRoot: Bool = true
    ) {
        self.rootDigests = rootDigests
        self.references = references
        self.dockerConfigDigest = dockerConfigDigest
        self.wholeRoot = wholeRoot
    }
}

/// Narrow lookup boundary used by container ancestor filters. Container
/// snapshots retain an immutable root descriptor even when their original tag
/// is later replaced, so filters must resolve to that identity rather than
/// comparing mutable reference strings.
protocol ImageReferenceResolving: Sendable {
    func identity(for identifier: String) async throws -> ResolvedImageFilterIdentity
}

struct LiveImageIdentityCatalog: ImageIdentityCatalog {
    private let contentStore = RemoteContentStoreClient()

    func list() async throws -> [ClientImage] {
        try await ClientImage.list()
    }

    func index(for image: ClientImage) async throws -> Index {
        try await image.index()
    }

    func index(digest: String) async throws -> Index? {
        try await contentStore.get(digest: digest)
    }

    func manifest(digest: String) async throws -> Manifest? {
        try await contentStore.get(digest: digest)
    }
}

/// A process-local, immutable-at-read-time index over Apple's reference-only image store.
///
/// Apple persists references to root OCI descriptors. Docker also treats root, platform
/// manifest, and image-config digests as image identities. Hydrating that DAG once keeps
/// request lookup bounded while preserving Docker's round-trip invariant: every ID emitted
/// by an API response can be accepted by a later image operation.
actor ImageIdentityResolver {
    private struct StoreRevision: Equatable, Sendable {
        let size: UInt64
        let modified: TimeInterval
        let fileNumber: UInt64
    }

    private struct Variant: Sendable {
        let platform: Platform
        let manifestDigest: String
        let configDigest: String
        let ancestorIndexDigests: Set<String>
        let pathDepth: Int
    }

    private struct Record: Sendable {
        let image: ClientImage
        let references: [String]
        let referenceConstraints: [String: RunnableImageIdentityConstraint]
        let storeReferences: [String]
        let repositories: Set<String>
        let repositoryDigests: [String]
        let rootDigest: String
        let variants: [Variant]
    }

    private struct Binding: Sendable {
        let rootDigest: String
        let kind: ImageIdentityKind
        let variantConstraint: RunnableImageIdentityConstraint
    }

    private struct AliasBinding: Sendable {
        let rootDigest: String
        let reference: String
        let variantConstraint: RunnableImageIdentityConstraint
    }

    private struct AliasSet: Sendable {
        var priority: Int
        var bindings: [AliasBinding]
    }

    private struct Snapshot: Sendable {
        var aliases: [String: AliasSet] = [:]
        var records: [String: Record] = [:]
        var digests: [String: [Binding]] = [:]
        var artifactRoots: [String: Set<String>] = [:]
        var artifactRepositories: [String: Set<String>] = [:]
        var sortedDigests: [String] = []
        var sortedArtifactDigests: [String] = []
    }

    private let systemConfig: ContainerSystemConfig
    private let catalog: any ImageIdentityCatalog
    private let stateURL: URL
    nonisolated let mutationCoordinator: ImageMutationCoordinator
    nonisolated let referenceConstraintStore: ImageReferenceConstraintStore
    private var snapshot = Snapshot()
    private var loaded = false
    private var storeRevision: StoreRevision?
    private struct InFlightRefresh: Sendable {
        let id: UUID
        let initialRevision: StoreRevision?
        let task: Task<Snapshot, Error>
    }
    private var inFlightRefresh: InFlightRefresh?

    init(
        systemConfig: ContainerSystemConfig,
        catalog: any ImageIdentityCatalog = LiveImageIdentityCatalog(),
        appSupportURL: URL? = nil,
        mutationCoordinator: ImageMutationCoordinator = ImageMutationCoordinator(),
        referenceConstraintStore: ImageReferenceConstraintStore? = nil
    ) {
        let resolvedAppSupportURL = appSupportURL ?? Self.defaultAppSupportURL()
        self.systemConfig = systemConfig
        self.catalog = catalog
        self.stateURL = resolvedAppSupportURL.appendingPathComponent("state.json")
        self.mutationCoordinator = mutationCoordinator
        self.referenceConstraintStore =
            referenceConstraintStore
            ?? ImageReferenceConstraintStore(
                appSupportURL: resolvedAppSupportURL
            )
    }

    func refresh() async throws {
        try await mutationCoordinator.stableRead { [self] in
            try await refreshUncoordinated()
        }
    }

    func invalidate() {
        loaded = false
        storeRevision = nil
        snapshot = Snapshot()
        inFlightRefresh?.task.cancel()
        inFlightRefresh = nil
    }

    private func refreshUncoordinated() async throws {
        while true {
            let refresh: InFlightRefresh
            if let existing = inFlightRefresh {
                refresh = existing
            } else {
                let id = UUID()
                let initialRevision = currentStoreRevision()
                let catalog = catalog
                let systemConfig = systemConfig
                let referenceConstraintStore = referenceConstraintStore
                let task = Task {
                    try await Self.buildSnapshot(
                        catalog: catalog,
                        systemConfig: systemConfig,
                        referenceConstraintStore: referenceConstraintStore
                    )
                }
                refresh = InFlightRefresh(id: id, initialRevision: initialRevision, task: task)
                inFlightRefresh = refresh
            }

            do {
                let next = try await refresh.task.value

                // Every waiter is allowed to finish the shared task. Exactly one will
                // still own `inFlightRefresh`; the rest observe its committed result.
                guard inFlightRefresh?.id == refresh.id else {
                    if loaded, storeRevision == currentStoreRevision() { return }
                    continue
                }

                let finalRevision = currentStoreRevision()
                inFlightRefresh = nil
                guard refresh.initialRevision == finalRevision else {
                    // The store changed while its OCI graph was being hydrated. Do not
                    // publish a mixed/obsolete graph; rebuild from the new revision.
                    continue
                }

                snapshot = next
                loaded = true
                storeRevision = finalRevision
                return
            } catch {
                if inFlightRefresh?.id == refresh.id {
                    inFlightRefresh = nil
                }
                throw error
            }
        }
    }

    private static func buildSnapshot(
        catalog: any ImageIdentityCatalog,
        systemConfig: ContainerSystemConfig,
        referenceConstraintStore: ImageReferenceConstraintStore
    ) async throws -> Snapshot {
        let images = try await catalog.list()
        let canonicalOwners = Self.canonicalTagOwners(
            images: images,
            systemConfig: systemConfig
        )
        let persistedConstraints =
            try await referenceConstraintStore
            .effectiveEntries(currentRootByReference: canonicalOwners)
        var grouped: [String: [ClientImage]] = [:]
        for image in images {
            grouped[image.digest, default: []].append(image)
        }

        var next = Snapshot()
        for rootDigest in grouped.keys.sorted() {
            guard let groupedImages = grouped[rootDigest] else { continue }
            let orderedImages = groupedImages.sorted { $0.reference < $1.reference }
            guard let representative = orderedImages.first else { continue }
            let storeReferences = orderedImages.map(\.reference)
            let references = Array(
                Set(
                    orderedImages.flatMap { image in
                        Self.claimedTags(image, systemConfig: systemConfig)
                    }.compactMap { canonical -> String? in
                        // If an authoritative canonical key exists, stale familiar
                        // spellings on other roots are physical retention only.
                        if let owner = canonicalOwners[canonical] {
                            return owner == Self.canonicalDigest(rootDigest) ? canonical : nil
                        }
                        // No exact canonical key: retain the pre-existing ambiguity
                        // instead of selecting a root by enumeration order.
                        return canonical
                    }
                )
            ).sorted()
            let identityCatalog = catalog
            let graph: OCIImageGraph
            do {
                let index = try await identityCatalog.index(
                    for: representative
                )
                graph = try await OCIImageGraphWalker.walk(
                    rootIndex: index,
                    loadIndex: { digest in
                        try await identityCatalog.index(digest: digest)
                    },
                    loadManifest: { digest in
                        try await identityCatalog.manifest(digest: digest)
                    }
                )
            } catch is OCIImageGraphError {
                // A malformed/depth-bomb root remains addressable only as a
                // non-runnable record. It must not poison hydration of every
                // unrelated image in Apple's shared store.
                graph = OCIImageGraph()
            } catch is DecodingError {
                // A corrupt root or nested OCI document is local to that
                // content graph. Transport/backend failures still propagate.
                graph = OCIImageGraph()
            } catch let error as ContainerizationError
                where error.code == .notFound
            {
                // ClientImage.index() reports a missing top-level content blob
                // as notFound (nested RemoteContentStore reads return nil).
                // This is local graph damage, not a catalog transport failure.
                graph = OCIImageGraph()
            }
            let variants = graph.entries.compactMap { entry -> Variant? in
                guard entry.isRunnableCandidate,
                    let manifest = entry.manifest,
                    let platform = entry.descriptor.platform
                else {
                    return nil
                }
                return Variant(
                    platform: platform,
                    manifestDigest: Self.canonicalDigest(
                        entry.descriptor.digest
                    ),
                    configDigest: Self.canonicalDigest(
                        manifest.config.digest
                    ),
                    ancestorIndexDigests: Set(
                        entry.runnableAncestorIndexDigests.map(
                            Self.canonicalDigest
                        )
                    ),
                    pathDepth: entry.pathDepth
                )
            }
            let runnableIndexDigests = Set(
                graph.runnableIndexDigests.map(Self.canonicalDigest)
            )
            let artifactDigests = Set(
                graph.artifactDigests.map(Self.canonicalDigest)
            )

            // Repository-scoped `name@digest` values are distribution
            // descriptors (index/manifest), never Docker config IDs. Config
            // digests remain valid only as bare image IDs and prefixes.
            let validRepositoryDigests = Set(
                [Self.canonicalDigest(rootDigest)]
                    + runnableIndexDigests
                    + variants.map(\.manifestDigest)
            )
            let storedRepositoryDigests = orderedImages.compactMap {
                image -> String? in
                guard !Self.isDanglingReference(image.reference),
                    let scoped = Self.scopedDigest(image.reference),
                    validRepositoryDigests.contains(
                        Self.canonicalDigest(scoped.digest)
                    )
                else {
                    return nil
                }
                return "\(scoped.repository)@\(Self.canonicalDigest(scoped.digest))"
            }
            let repositories = Set(
                storedRepositoryDigests.compactMap(Self.repository)
            )
            let physicalArtifactRepositoryDigests = orderedImages.compactMap {
                image -> (digest: String, reference: String)? in
                guard let scoped = Self.scopedDigest(image.reference),
                    artifactDigests.contains(Self.canonicalDigest(scoped.digest))
                else {
                    return nil
                }
                let digest = Self.canonicalDigest(scoped.digest)
                return (digest, "\(scoped.repository)@\(digest)")
            }
            // RepoDigests are durable distribution associations created by a
            // digest pull/load. A local tag does not prove that its Apple root
            // digest exists in (or was accepted by) that repository, so never
            // synthesize `tag-repository@root` aliases from tags alone.
            let repositoryDigests = Array(Set(storedRepositoryDigests)).sorted()
            let referenceConstraints = Dictionary(
                uniqueKeysWithValues: references.map { reference in
                    (
                        reference,
                        Self.persistedConstraint(
                            for: reference,
                            in: persistedConstraints,
                            systemConfig: systemConfig
                        )
                    )
                }
            )

            let record = Record(
                image: representative,
                references: references,
                referenceConstraints: referenceConstraints,
                storeReferences: storeReferences,
                repositories: repositories,
                repositoryDigests: repositoryDigests,
                rootDigest: Self.canonicalDigest(rootDigest),
                variants: variants
            )
            next.records[record.rootDigest] = record
            for digest in artifactDigests {
                next.artifactRoots[digest, default: []].insert(
                    record.rootDigest
                )
                next.artifactRepositories[digest, default: []].formUnion(
                    physicalArtifactRepositoryDigests.lazy
                        .filter { $0.digest == digest }
                        .map(\.reference)
                )
            }
            next.digests[record.rootDigest, default: []].append(
                Binding(
                    rootDigest: record.rootDigest,
                    kind: .root,
                    variantConstraint: .unconstrained
                ))
            for digest in runnableIndexDigests {
                next.digests[digest, default: []].append(
                    Binding(
                        rootDigest: record.rootDigest,
                        kind: .root,
                        variantConstraint: .descendantOfIndex(digest)
                    )
                )
            }

            for image in orderedImages {
                if DockerImageReferenceSemantics.isBareSHA256Identifier(
                    image.reference
                ) {
                    // The digest table is the only public identity for a
                    // literal digest store key. A plain alias would erase
                    // manifest/config platform semantics.
                    continue
                }
                if Self.scopedDigest(image.reference) != nil {
                    // A repository-scoped digest is likewise resolved through
                    // the digest graph. The one compatibility exception is an
                    // older Apple load's internal `untagged@...` key: its OCI
                    // name annotation remains a low-priority tag alias.
                    guard Self.isLegacyUntaggedReference(image.reference),
                        let annotatedName = Self.annotationName(image)
                    else {
                        continue
                    }
                    Self.addReferenceAliases(
                        annotatedName,
                        storedReference: image.reference,
                        rootDigest: record.rootDigest,
                        variantConstraint: Self.persistedConstraint(
                            for: annotatedName,
                            in: persistedConstraints,
                            systemConfig: systemConfig
                        ),
                        systemConfig: systemConfig,
                        priority: 0,
                        to: &next.aliases
                    )
                    continue
                }
                let normalized = try? ClientImage.normalizeReference(
                    image.reference,
                    containerSystemConfig: systemConfig
                )
                Self.addReferenceAliases(
                    image.reference,
                    storedReference: image.reference,
                    rootDigest: record.rootDigest,
                    variantConstraint: Self.persistedConstraint(
                        for: image.reference,
                        in: persistedConstraints,
                        systemConfig: systemConfig
                    ),
                    systemConfig: systemConfig,
                    // A normalized store key is the canonical Docker tag owner.
                    // Familiar Apple keys remain fallbacks and are removed by the
                    // mutation boundary after replacement.
                    priority: normalized == image.reference ? 2 : 1,
                    to: &next.aliases
                )
                // Older Apple loads used an untagged physical key and kept the
                // requested name only in OCI annotations. Accept those names as
                // a lowest-priority compatibility fallback. A root deliberately
                // preserved as `moby-dangling` retains the same annotations but
                // must never regain ownership from them.
            }
            for variant in variants {
                next.digests[variant.manifestDigest, default: []].append(
                    Binding(
                        rootDigest: record.rootDigest,
                        kind: .manifest(variant.platform),
                        variantConstraint: .exactManifest(
                            manifestDigest: variant.manifestDigest,
                            configDigest: variant.configDigest
                        )
                    ))
                next.digests[variant.configDigest, default: []].append(
                    Binding(
                        rootDigest: record.rootDigest,
                        kind: .config(variant.platform),
                        variantConstraint: .exactManifest(
                            manifestDigest: variant.manifestDigest,
                            configDigest: variant.configDigest
                        )
                    ))
            }
        }
        next.sortedDigests = next.digests.keys.sorted()
        next.sortedArtifactDigests = next.artifactRoots.keys.sorted()
        return next
    }

    func resolve(_ input: String) async throws -> ResolvedImageIdentity {
        try await mutationCoordinator.stableRead { [self] in
            try await resolveUncoordinated(input)
        }
    }

    /// Lookup for code that already holds `mutationCoordinator`'s writer lock.
    /// Calling the stable public lookup there would wait on itself.
    func resolveDuringMutation(_ input: String) async throws -> ResolvedImageIdentity {
        try await resolveUncoordinated(input)
    }

    private func resolveUncoordinated(_ input: String) async throws -> ResolvedImageIdentity {
        if !loaded || storeRevision != currentStoreRevision() {
            try await refreshUncoordinated()
        }

        if let aliases = snapshot.aliases[input] ?? normalizedAlias(input).flatMap({ snapshot.aliases[$0] }) {
            let roots = Set(aliases.bindings.map(\.rootDigest))
            guard roots.count == 1, let alias = aliases.bindings.first,
                let record = snapshot.records[alias.rootDigest]
            else {
                throw ImageIdentityResolutionError.ambiguous(input)
            }
            guard !record.variants.isEmpty else {
                throw ImageIdentityResolutionError.nonRunnable(input)
            }
            return resolved(
                record: record,
                kind: .reference,
                variantConstraint: alias.variantConstraint,
                reference: alias.reference,
                selectedStoreReference: alias.reference
            )
        }

        if let scoped = scopedDigest(input) {
            let digest = Self.canonicalDigest(scoped.digest)
            let repositoryDigest = "\(scoped.repository)@\(digest)"
            let bindings = snapshot.digests[digest] ?? []
            let matching = bindings.filter { binding in
                guard let record = snapshot.records[binding.rootDigest] else { return false }
                return Self.isRepositoryDigestKind(binding.kind)
                    && record.repositoryDigests.contains(repositoryDigest)
            }
            if matching.isEmpty,
                snapshot.artifactRepositories[digest]?.contains(repositoryDigest) == true
            {
                throw ImageIdentityResolutionError.nonRunnable(input)
            }
            return try resolveBindings(
                matching,
                input: input,
                storeSelector: input
            )
        }

        guard let prefix = Self.digestPrefix(input) else {
            throw ImageIdentityResolutionError.notFound(input)
        }
        let canonical = "sha256:\(prefix)"
        if prefix.count == 64 {
            let bindings = snapshot.digests[canonical] ?? []
            if bindings.isEmpty,
                snapshot.artifactRoots[canonical]?.isEmpty == false
            {
                throw ImageIdentityResolutionError.nonRunnable(input)
            }
            return try resolveBindings(bindings, input: input)
        }

        let runnableMatches = Self.matchingDigests(
            snapshot.sortedDigests,
            prefix: canonical
        )
        let artifactMatches = Self.matchingDigests(
            snapshot.sortedArtifactDigests,
            prefix: canonical
        )
        let matchedDigests = Set(runnableMatches + artifactMatches)
        guard matchedDigests.count <= 1 else {
            throw ImageIdentityResolutionError.ambiguous(input)
        }
        guard let matchedDigest = matchedDigests.first else {
            throw ImageIdentityResolutionError.notFound(input)
        }
        let bindings = snapshot.digests[matchedDigest] ?? []
        if bindings.isEmpty {
            throw ImageIdentityResolutionError.nonRunnable(input)
        }
        return try resolveBindings(bindings, input: input)
    }

    private func resolveBindings(
        _ bindings: [Binding],
        input: String,
        storeSelector: String? = nil
    ) throws -> ResolvedImageIdentity {
        guard !bindings.isEmpty else {
            throw ImageIdentityResolutionError.notFound(input)
        }
        let normalizedSelector = storeSelector.flatMap(normalizedAlias)
        guard
            let selectedRank = bindings.map({
                Self.kindRank($0.kind)
            }).min()
        else {
            throw ImageIdentityResolutionError.notFound(input)
        }
        let candidates = bindings.filter {
            Self.kindRank($0.kind) == selectedRank
                && snapshot.records[$0.rootDigest]?.variants.isEmpty == false
        }
        guard !candidates.isEmpty else {
            throw ImageIdentityResolutionError.nonRunnable(input)
        }

        // A full content digest remains one immutable identity even when it is
        // reachable from several root indexes. Prefer an exact physical
        // selector when present, then choose a stable variant/root. Config IDs
        // may legitimately have multiple parent manifests (for example layers
        // compressed differently with the same diffIDs); the config content is
        // still the Docker image identity.
        let ordered = candidates.sorted { left, right in
            let leftRecord = snapshot.records[left.rootDigest]
            let rightRecord = snapshot.records[right.rootDigest]
            let leftHasSelector =
                leftRecord?.storeReferences.contains {
                    $0 == storeSelector || $0 == normalizedSelector
                } ?? false
            let rightHasSelector =
                rightRecord?.storeReferences.contains {
                    $0 == storeSelector || $0 == normalizedSelector
                } ?? false
            if leftHasSelector != rightHasSelector {
                return leftHasSelector
            }
            let leftConstraint = Self.constraintSortKey(
                left.variantConstraint
            )
            let rightConstraint = Self.constraintSortKey(
                right.variantConstraint
            )
            if leftConstraint != rightConstraint {
                return leftConstraint < rightConstraint
            }
            if left.rootDigest != right.rootDigest {
                return left.rootDigest < right.rootDigest
            }
            return Self.kindSortKey(left.kind) < Self.kindSortKey(right.kind)
        }
        guard let selected = ordered.first,
            let record = snapshot.records[selected.rootDigest]
        else {
            throw ImageIdentityResolutionError.nonRunnable(input)
        }

        // The same manifest digest must always name the same config document.
        // Multiple config-ID parents are allowed and resolved deterministically.
        if case .manifest = selected.kind {
            let constraints = Set(candidates.map(\.variantConstraint))
            guard constraints.count == 1 else {
                throw ImageIdentityResolutionError.ambiguous(input)
            }
        }
        var ownerRecordsByRoot: [String: Record] = [:]
        for binding in candidates {
            if let candidateRecord = snapshot.records[binding.rootDigest] {
                ownerRecordsByRoot[binding.rootDigest] = candidateRecord
            }
        }
        let ownerRecords = ownerRecordsByRoot.values.sorted {
            $0.rootDigest < $1.rootDigest
        }
        let selectedStoreReference = storeSelector.flatMap { selector in
            record.storeReferences.first {
                $0 == selector || $0 == normalizedSelector
            }
        }
        return resolved(
            record: record,
            kind: selected.kind,
            variantConstraint: selected.variantConstraint,
            selectedStoreReference: selectedStoreReference,
            ownerRecords: ownerRecords
        )
    }

    private func resolved(
        record: Record,
        kind: ImageIdentityKind,
        variantConstraint: RunnableImageIdentityConstraint = .unconstrained,
        reference: String? = nil,
        selectedStoreReference: String? = nil,
        ownerRecords: [Record]? = nil
    ) -> ResolvedImageIdentity {
        let resolvedReference = reference ?? record.image.reference
        let image = ClientImage(
            description: ImageDescription(
                reference: resolvedReference,
                descriptor: record.image.descriptor
            ))
        let records = ownerRecords ?? [record]
        let dockerConfigDigest =
            Self.preferredVariant(
                in: record.variants,
                constrainedBy: variantConstraint
            )?.configDigest ?? record.rootDigest
        let scopesReferencesToConfig =
            kind != .root
            || variantConstraint != .unconstrained
        func visibleReferences(in candidate: Record) -> [String] {
            guard scopesReferencesToConfig else { return candidate.references }
            return candidate.references.filter { reference in
                let constraint =
                    candidate.referenceConstraints[reference]
                    ?? .unconstrained
                return Self.preferredVariant(
                    in: candidate.variants,
                    constrainedBy: constraint
                )?.configDigest == dockerConfigDigest
            }
        }
        let owners = records.map {
            ResolvedImageOwner(
                image: $0.image,
                references: visibleReferences(in: $0),
                storeReferences: $0.storeReferences,
                repositoryDigests: $0.repositoryDigests
            )
        }
        let references = Array(
            Set(records.flatMap(visibleReferences))
        ).sorted()
        let storeReferences = Array(
            Set(records.flatMap(\.storeReferences))
        ).sorted()
        let repositoryDigests = Array(
            Set(records.flatMap(\.repositoryDigests))
        ).sorted()
        return ResolvedImageIdentity(
            image: image,
            reference: resolvedReference,
            references: references,
            storeReferences: storeReferences,
            repositoryDigests: repositoryDigests,
            selectedStoreReference: selectedStoreReference,
            kind: kind,
            variantConstraint: variantConstraint,
            owners: owners,
            dockerConfigDigest: dockerConfigDigest
        )
    }

    private func normalizedAlias(_ input: String) -> String? {
        try? ClientImage.normalizeReference(input, containerSystemConfig: systemConfig)
    }

    private static func addReferenceAliases(
        _ reference: String,
        storedReference: String,
        rootDigest: String,
        variantConstraint: RunnableImageIdentityConstraint,
        systemConfig: ContainerSystemConfig,
        priority: Int,
        to aliases: inout [String: AliasSet]
    ) {
        let binding = AliasBinding(
            rootDigest: rootDigest,
            reference: storedReference,
            variantConstraint: variantConstraint
        )
        addAlias(reference, binding: binding, priority: priority, to: &aliases)
        if let normalized = try? ClientImage.normalizeReference(reference, containerSystemConfig: systemConfig) {
            addAlias(normalized, binding: binding, priority: priority, to: &aliases)
        }
        if let familiar = try? ClientImage.denormalizeReference(reference, containerSystemConfig: systemConfig) {
            addAlias(familiar, binding: binding, priority: priority, to: &aliases)
        }
    }

    private static func addAlias(
        _ alias: String,
        binding: AliasBinding,
        priority: Int,
        to aliases: inout [String: AliasSet]
    ) {
        guard var existing = aliases[alias] else {
            aliases[alias] = AliasSet(priority: priority, bindings: [binding])
            return
        }
        if priority > existing.priority {
            aliases[alias] = AliasSet(priority: priority, bindings: [binding])
            return
        }
        guard priority == existing.priority else { return }
        if !existing.bindings.contains(where: {
            $0.rootDigest == binding.rootDigest
                && $0.reference == binding.reference
                && $0.variantConstraint == binding.variantConstraint
        }) {
            existing.bindings.append(binding)
            aliases[alias] = existing
        }
    }

    private static func repository(of reference: String) -> String? {
        (try? Reference.parse(reference))?.name
    }

    private static func canonicalTag(
        _ reference: String,
        systemConfig: ContainerSystemConfig
    ) -> String? {
        guard !isDanglingReference(reference),
            !DockerImageReferenceSemantics.isBareSHA256Identifier(reference),
            let parsed = try? Reference.parse(reference),
            parsed.digest == nil,
            let normalized = try? ClientImage.normalizeReference(
                reference,
                containerSystemConfig: systemConfig
            ),
            (try? Reference.parse(normalized))?.digest == nil
        else {
            return nil
        }
        return normalized
    }

    private static func persistedConstraint(
        for reference: String,
        in entries: [String: ImageReferenceConstraintStore.Entry],
        systemConfig: ContainerSystemConfig
    ) -> RunnableImageIdentityConstraint {
        guard
            let canonical = canonicalTag(
                reference,
                systemConfig: systemConfig
            )
        else {
            return .unconstrained
        }
        return entries[canonical]?.constraint ?? .unconstrained
    }

    /// Maps a canonical Docker tag to its authoritative root. An exact
    /// normalized store key wins. Without one, a sole root is authoritative;
    /// multiple familiar roots intentionally remain ambiguous.
    private static func canonicalTagOwners(
        images: [ClientImage],
        systemConfig: ContainerSystemConfig
    ) -> [String: String] {
        let claims = Dictionary(
            grouping: images.flatMap { image in
                claimedTags(image, systemConfig: systemConfig).map { ($0, image) }
            },
            by: { $0.0 }
        )
        var owners: [String: String] = [:]
        for (canonical, candidates) in claims {
            let exactRoots = Set(
                candidates.compactMap { _, image in
                    image.reference == canonical ? canonicalDigest(image.digest) : nil
                }
            )
            if exactRoots.count == 1, let root = exactRoots.first {
                owners[canonical] = root
                continue
            }
            guard exactRoots.isEmpty else { continue }
            let roots = Set(candidates.map { canonicalDigest($0.1.digest) })
            if roots.count == 1 {
                owners[canonical] = roots.first
            }
        }
        return owners
    }

    private static func isDanglingReference(_ reference: String) -> Bool {
        DockerImageReferenceSemantics.isInternalReference(reference)
    }

    private static func isLegacyUntaggedReference(_ reference: String) -> Bool {
        reference.hasPrefix("untagged@sha256:") || reference.hasPrefix("<none>")
    }

    private static func claimedTags(
        _ image: ClientImage,
        systemConfig: ContainerSystemConfig
    ) -> Set<String> {
        if let physicalTag = canonicalTag(
            image.reference,
            systemConfig: systemConfig
        ) {
            return [physicalTag]
        }
        guard isLegacyUntaggedReference(image.reference) else { return [] }
        guard let annotatedName = annotationName(image),
            let annotatedTag = canonicalTag(
                annotatedName,
                systemConfig: systemConfig
            )
        else {
            return []
        }
        return [annotatedTag]
    }

    private static func annotationName(_ image: ClientImage) -> String? {
        let annotations = image.descriptor.annotations ?? [:]
        return annotations[AnnotationKeys.containerizationImageName]
            ?? annotations[AnnotationKeys.containerdImageName]
            ?? annotations[AnnotationKeys.openContainersImageName]
    }

    private static func scopedDigest(_ input: String) -> (repository: String, digest: String)? {
        guard let parsed = try? Reference.parse(input), let digest = parsed.digest else { return nil }
        return (parsed.name, digest)
    }

    private func scopedDigest(_ input: String) -> (repository: String, digest: String)? {
        Self.scopedDigest(normalizedAlias(input) ?? input)
    }

    private static func digestPrefix(_ input: String) -> String? {
        let raw = input.hasPrefix("sha256:") ? String(input.dropFirst(7)) : input
        guard (4...64).contains(raw.count), raw.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) }) else {
            return nil
        }
        return raw
    }

    private static func canonicalDigest(_ digest: String) -> String {
        digest.hasPrefix("sha256:") ? digest : "sha256:\(digest)"
    }

    private static func kindRank(_ kind: ImageIdentityKind) -> Int {
        switch kind {
        case .config: 0
        case .manifest: 1
        case .root: 2
        case .reference: 3
        }
    }

    private static func isRepositoryDigestKind(
        _ kind: ImageIdentityKind
    ) -> Bool {
        switch kind {
        case .root, .manifest:
            return true
        case .reference, .config:
            return false
        }
    }

    private static func preferredVariant(
        in variants: [Variant],
        constrainedBy constraint: RunnableImageIdentityConstraint,
        hostPlatform: Platform = requestedOrDefaultPlatform(nil)
    ) -> Variant? {
        variants.filter { variant in
            switch constraint {
            case .unconstrained:
                return true
            case .descendantOfIndex(let digest):
                return variant.ancestorIndexDigests.contains(digest)
            case .exactManifest(let manifestDigest, let configDigest):
                return variant.manifestDigest == manifestDigest
                    && variant.configDigest == configDigest
            }
        }.sorted { left, right in
            let leftRank = platformPreferenceRank(
                left.platform,
                preferred: hostPlatform
            )
            let rightRank = platformPreferenceRank(
                right.platform,
                preferred: hostPlatform
            )
            if leftRank != rightRank { return leftRank < rightRank }
            let leftPlatform = stablePlatformKey(left.platform)
            let rightPlatform = stablePlatformKey(right.platform)
            if leftPlatform != rightPlatform {
                return leftPlatform < rightPlatform
            }
            if left.pathDepth != right.pathDepth {
                return left.pathDepth < right.pathDepth
            }
            if left.manifestDigest != right.manifestDigest {
                return left.manifestDigest < right.manifestDigest
            }
            return left.configDigest < right.configDigest
        }.first
    }

    private static func platformPreferenceRank(
        _ platform: Platform,
        preferred: Platform
    ) -> Int {
        if platform == preferred { return 0 }
        if platform.architecture == preferred.architecture,
            platform.os == preferred.os
        {
            return 1
        }
        if platform.architecture == preferred.architecture { return 2 }
        if platform.os == preferred.os { return 3 }
        return 4
    }

    private static func stablePlatformKey(_ platform: Platform) -> String {
        [
            platform.os,
            platform.architecture,
            platform.variant ?? "",
            platform.osVersion ?? "",
            (platform.osFeatures ?? []).sorted().joined(separator: ","),
        ].joined(separator: "\u{0}")
    }

    private static func constraintSortKey(
        _ constraint: RunnableImageIdentityConstraint
    ) -> String {
        switch constraint {
        case .unconstrained:
            return "0"
        case .descendantOfIndex(let digest):
            return "1\u{0}\(digest)"
        case .exactManifest(let manifestDigest, let configDigest):
            return "2\u{0}\(manifestDigest)\u{0}\(configDigest)"
        }
    }

    private static func kindSortKey(_ kind: ImageIdentityKind) -> String {
        switch kind {
        case .reference:
            return "reference"
        case .root:
            return "root"
        case .manifest(let platform):
            return "manifest\u{0}\(platform.description)"
        case .config(let platform):
            return "config\u{0}\(platform.description)"
        }
    }

    private static func lowerBound(_ values: [String], _ target: String) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = low + (high - low) / 2
            if values[middle] < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private static func matchingDigests(
        _ sortedDigests: [String],
        prefix: String
    ) -> [String] {
        var matches: [String] = []
        var index = lowerBound(sortedDigests, prefix)
        while index < sortedDigests.count {
            let digest = sortedDigests[index]
            guard digest.hasPrefix(prefix) else { break }
            matches.append(digest)
            index += 1
        }
        return matches
    }

    private func currentStoreRevision() -> StoreRevision? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: stateURL.path) else {
            return nil
        }
        return StoreRevision(
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        )
    }

    private static func defaultAppSupportURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.apple.container")
    }
}

extension ImageIdentityResolver: ImageReferenceResolving {
    func identity(for identifier: String) async throws -> ResolvedImageFilterIdentity {
        let resolved = try await resolve(identifier)
        return ResolvedImageFilterIdentity(
            rootDigests: resolved.rootDigests,
            references: resolved.references,
            dockerConfigDigest: resolved.dockerConfigDigest,
            wholeRoot: resolved.kind == .root
                && resolved.variantConstraint == .unconstrained
        )
    }
}
