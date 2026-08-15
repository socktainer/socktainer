import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerizationOCI
import Foundation

protocol OCIImageDocumentProviding: Sendable {
    func index(digest: String) async throws -> Index?
    func manifest(digest: String) async throws -> Manifest?
}

extension OCIImageDocumentProviding {
    /// Direct-manifest providers written before nested OCI indexes were
    /// supported remain valid. Production and recursive-test providers
    /// override this to hydrate an index descriptor by immutable digest.
    func index(digest: String) async throws -> Index? { nil }
}

protocol RunnableImageContentProviding: OCIImageDocumentProviding {
    func index(for image: ClientImage) async throws -> Index
    func config(digest: String) async throws -> ContainerizationOCI.Image?
}

struct LiveRunnableImageContentProvider: RunnableImageContentProviding {
    private let contentStore = RemoteContentStoreClient()

    func index(for image: ClientImage) async throws -> Index {
        try await image.index()
    }

    func index(digest: String) async throws -> Index? {
        try await contentStore.get(digest: digest)
    }

    func manifest(digest: String) async throws -> Manifest? {
        try await contentStore.get(digest: digest)
    }

    func config(digest: String) async throws -> ContainerizationOCI.Image? {
        try await contentStore.get(digest: digest)
    }
}

struct RunnableImageVariant: Sendable {
    let descriptor: Descriptor
    let platform: Platform
    let manifest: Manifest
    let config: ContainerizationOCI.Image
    /// One means a manifest directly in the stored root index. Values greater
    /// than one require an exact synthetic snapshot because Apple's native
    /// platform lookup does not recursively select the immutable leaf.
    let pathDepth: Int

    init(
        descriptor: Descriptor,
        platform: Platform,
        manifest: Manifest,
        config: ContainerizationOCI.Image,
        pathDepth: Int = 1
    ) {
        self.descriptor = descriptor
        self.platform = platform
        self.manifest = manifest
        self.config = config
        self.pathDepth = pathDepth
    }

    var contentSize: Int64 {
        manifest.config.size + manifest.layers.reduce(0) { $0 + $1.size }
    }

    var totalSize: Int64 {
        descriptor.size + contentSize
    }
}

struct ResolvedImageDescriptor: Sendable {
    enum Kind: Sendable, Equatable {
        case image
        case artifact
    }

    let descriptor: Descriptor
    let manifest: Manifest?
    let kind: Kind
    let runnableVariant: RunnableImageVariant?
    let artifactSubjectDigest: String?
    let pathDepth: Int
    let documentAvailable: Bool
    /// Runnable intermediate indexes on the path from the stored root to this
    /// leaf. Docker accepts each immutable index digest as image identity.
    let runnableAncestorIndexDigests: [String]

    init(
        descriptor: Descriptor,
        manifest: Manifest?,
        kind: Kind,
        runnableVariant: RunnableImageVariant?,
        artifactSubjectDigest: String? = nil,
        pathDepth: Int = 1,
        documentAvailable: Bool? = nil,
        runnableAncestorIndexDigests: [String] = []
    ) {
        self.descriptor = descriptor
        self.manifest = manifest
        self.kind = kind
        self.runnableVariant = runnableVariant
        self.artifactSubjectDigest = artifactSubjectDigest
        self.pathDepth = pathDepth
        self.documentAvailable = documentAvailable ?? (manifest != nil)
        self.runnableAncestorIndexDigests =
            runnableAncestorIndexDigests
    }

    var contentSize: Int64 {
        guard let manifest else { return 0 }
        return manifest.config.size + manifest.layers.reduce(0) { $0 + $1.size }
    }

    var totalSize: Int64 {
        descriptor.size + contentSize
    }
}

enum OCIImageGraphError: Error, LocalizedError, Equatable {
    case indexNestingTooDeep
    case graphTooLarge

    var errorDescription: String? {
        switch self {
        case .indexNestingTooDeep:
            return "the image nests OCI indexes beyond the supported depth"
        case .graphTooLarge:
            return "the OCI image graph exceeds the supported descriptor limit"
        }
    }
}

/// Content-level result shared by runtime selection and Docker image identity
/// indexing. Keeping recursion here prevents create/inspect and digest lookup
/// from disagreeing about what an OCI root means.
struct OCIImageGraph: Sendable {
    struct Entry: Sendable {
        let descriptor: Descriptor
        let manifest: Manifest?
        let kind: ResolvedImageDescriptor.Kind
        let artifactSubjectDigest: String?
        let pathDepth: Int
        let documentAvailable: Bool
        let runnableAncestorIndexDigests: [String]

        var isRunnableCandidate: Bool {
            kind == .image && manifest != nil
                && RunnableImageSelector.hasRunnablePlatform(
                    descriptor.platform
                )
        }

        func addingRunnableAncestor(_ digest: String) -> Self {
            guard isRunnableCandidate else { return self }
            return Self(
                descriptor: descriptor,
                manifest: manifest,
                kind: kind,
                artifactSubjectDigest: artifactSubjectDigest,
                pathDepth: pathDepth,
                documentAvailable: documentAvailable,
                runnableAncestorIndexDigests: [digest] + runnableAncestorIndexDigests
            )
        }
    }

    var entries: [Entry] = []
    var runnableIndexDigests: Set<String> = []
    var artifactDigests: Set<String> = []

    var hasRunnableImage: Bool {
        entries.contains(where: \.isRunnableCandidate)
    }

    mutating func merge(_ other: Self) {
        entries.append(contentsOf: other.entries)
        runnableIndexDigests.formUnion(other.runnableIndexDigests)
        artifactDigests.formUnion(other.artifactDigests)
    }
}

/// Bounded, cycle-safe OCI descriptor walker. Its memoization key includes the
/// full occurrence metadata and remaining depth, while cycle-dependent partial
/// results are deliberately never cached. This preserves descriptor-level
/// artifact/platform semantics when one content digest appears in multiple
/// places and collapses shared index DAGs without request-time store scans.
enum OCIImageGraphWalker {
    typealias IndexLoader =
        @Sendable (String) async throws -> Index?
    typealias ManifestLoader =
        @Sendable (String) async throws -> Manifest?

    private static let maximumDepth = 32
    private static let maximumVisitedDescriptors = 10_000
    private static let maximumOutputEntries = 10_000

    private actor Budget {
        private var visitedDescriptors = 0

        func recordVisit() throws {
            visitedDescriptors += 1
            guard
                visitedDescriptors
                    <= OCIImageGraphWalker.maximumVisitedDescriptors
            else {
                throw OCIImageGraphError.graphTooLarge
            }
        }

        func validateMerge(existing: Int, adding: Int) throws {
            guard
                existing <= OCIImageGraphWalker.maximumOutputEntries - adding
            else {
                throw OCIImageGraphError.graphTooLarge
            }
        }
    }

    private struct ContentKey: Hashable, Sendable {
        let digest: String
        let mediaType: String
    }

    private struct CacheKey: Hashable, Sendable {
        let encodedDescriptor: Data
        let remainingDepth: Int
    }

    private struct NodeResult: Sendable {
        var graph: OCIImageGraph
        let encounteredCycle: Bool
    }

    private actor Cache {
        private var entries: [CacheKey: NodeResult] = [:]

        func value(for key: CacheKey) -> NodeResult? {
            entries[key]
        }

        func insert(_ value: NodeResult, for key: CacheKey) {
            entries[key] = value
        }
    }

    static func walk(
        rootIndex: Index,
        loadIndex: @escaping IndexLoader,
        loadManifest: @escaping ManifestLoader
    ) async throws -> OCIImageGraph {
        let cache = Cache()
        let budget = Budget()
        var graph = OCIImageGraph()
        for descriptor in rootIndex.manifests {
            let result = try await visit(
                descriptor,
                depth: 1,
                visiting: [],
                cache: cache,
                budget: budget,
                loadIndex: loadIndex,
                loadManifest: loadManifest
            )
            try await budget.validateMerge(
                existing: graph.entries.count,
                adding: result.graph.entries.count
            )
            graph.merge(result.graph)
        }
        return graph
    }

    private static func visit(
        _ descriptor: Descriptor,
        depth: Int,
        visiting: Set<ContentKey>,
        cache: Cache,
        budget: Budget,
        loadIndex: @escaping IndexLoader,
        loadManifest: @escaping ManifestLoader
    ) async throws -> NodeResult {
        try await budget.recordVisit()
        guard depth <= maximumDepth else {
            throw OCIImageGraphError.indexNestingTooDeep
        }

        let contentKey = ContentKey(
            digest: descriptor.digest,
            mediaType: descriptor.mediaType
        )
        if isIndex(descriptor.mediaType), visiting.contains(contentKey) {
            return NodeResult(
                graph: OCIImageGraph(),
                encounteredCycle: true
            )
        }

        let cacheKey = try CacheKey(
            encodedDescriptor: encodedDescriptor(descriptor),
            remainingDepth: maximumDepth - depth
        )
        if let cached = await cache.value(for: cacheKey) {
            return cached
        }

        let result: NodeResult
        if isManifest(descriptor.mediaType) {
            result = try await visitManifest(
                descriptor,
                depth: depth,
                loadManifest: loadManifest
            )
        } else if isIndex(descriptor.mediaType) {
            result = try await visitIndex(
                descriptor,
                depth: depth,
                visiting: visiting.union([contentKey]),
                cache: cache,
                budget: budget,
                loadIndex: loadIndex,
                loadManifest: loadManifest
            )
        } else {
            let classification = OCIArtifactSemantics.classify(
                descriptor: descriptor
            )
            var graph = OCIImageGraph()
            graph.entries.append(
                .init(
                    descriptor: descriptor,
                    manifest: nil,
                    kind: classification.isArtifact
                        ? .artifact : .image,
                    artifactSubjectDigest: classification.subjectDigest,
                    pathDepth: depth,
                    documentAvailable: false,
                    runnableAncestorIndexDigests: []
                )
            )
            if classification.isArtifact {
                graph.artifactDigests.insert(descriptor.digest)
            }
            result = NodeResult(
                graph: graph,
                encounteredCycle: false
            )
        }

        // A cycle result is path-dependent: caching it would make a later
        // acyclic occurrence inherit an incomplete graph.
        if !result.encounteredCycle {
            await cache.insert(result, for: cacheKey)
        }
        return result
    }

    private static func visitManifest(
        _ descriptor: Descriptor,
        depth: Int,
        loadManifest: @escaping ManifestLoader
    ) async throws -> NodeResult {
        let manifest = try await loadManifest(descriptor.digest)
        let classification = OCIArtifactSemantics.classify(
            descriptor: descriptor,
            manifest: manifest
        )
        var graph = OCIImageGraph()
        graph.entries.append(
            .init(
                descriptor: descriptor,
                manifest: manifest,
                kind: classification.isArtifact ? .artifact : .image,
                artifactSubjectDigest: classification.subjectDigest,
                pathDepth: depth,
                documentAvailable: manifest != nil,
                runnableAncestorIndexDigests: []
            )
        )
        if classification.isArtifact {
            graph.artifactDigests.insert(descriptor.digest)
            if let manifest {
                graph.artifactDigests.insert(manifest.config.digest)
            }
        }
        return NodeResult(graph: graph, encounteredCycle: false)
    }

    private static func visitIndex(
        _ descriptor: Descriptor,
        depth: Int,
        visiting: Set<ContentKey>,
        cache: Cache,
        budget: Budget,
        loadIndex: @escaping IndexLoader,
        loadManifest: @escaping ManifestLoader
    ) async throws -> NodeResult {
        let index = try await loadIndex(descriptor.digest)
        let classification = OCIArtifactSemantics.classify(
            descriptor: descriptor,
            index: index
        )

        // Artifact indexes are terminal metadata documents. Descending into
        // their children could incorrectly promote their subjects or payloads
        // to runnable Docker image identities.
        if classification.isArtifact {
            var graph = OCIImageGraph()
            graph.entries.append(
                .init(
                    descriptor: descriptor,
                    manifest: nil,
                    kind: .artifact,
                    artifactSubjectDigest: classification.subjectDigest,
                    pathDepth: depth,
                    documentAvailable: index != nil,
                    runnableAncestorIndexDigests: []
                )
            )
            graph.artifactDigests.insert(descriptor.digest)
            return NodeResult(graph: graph, encounteredCycle: false)
        }

        guard let index else {
            var graph = OCIImageGraph()
            graph.entries.append(
                .init(
                    descriptor: descriptor,
                    manifest: nil,
                    kind: .image,
                    artifactSubjectDigest: nil,
                    pathDepth: depth,
                    documentAvailable: false,
                    runnableAncestorIndexDigests: []
                )
            )
            return NodeResult(graph: graph, encounteredCycle: false)
        }

        var graph = OCIImageGraph()
        var encounteredCycle = false
        for child in index.manifests {
            let childResult = try await visit(
                child,
                depth: depth + 1,
                visiting: visiting,
                cache: cache,
                budget: budget,
                loadIndex: loadIndex,
                loadManifest: loadManifest
            )
            try await budget.validateMerge(
                existing: graph.entries.count,
                adding: childResult.graph.entries.count
            )
            graph.merge(childResult.graph)
            encounteredCycle =
                encounteredCycle || childResult.encounteredCycle
        }

        if graph.hasRunnableImage {
            graph.runnableIndexDigests.insert(descriptor.digest)
            graph.entries = graph.entries.map {
                $0.addingRunnableAncestor(descriptor.digest)
            }
        }
        return NodeResult(
            graph: graph,
            encounteredCycle: encounteredCycle
        )
    }

    private static func encodedDescriptor(
        _ descriptor: Descriptor
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(descriptor)
    }

    private static func isIndex(_ mediaType: String) -> Bool {
        mediaType == MediaTypes.index
            || mediaType == MediaTypes.dockerManifestList
    }

    private static func isManifest(_ mediaType: String) -> Bool {
        mediaType == MediaTypes.imageManifest
            || mediaType == MediaTypes.dockerManifest
    }
}

/// Resolves runnable OCI variants by immutable descriptor/config digest.
///
/// Apple's `ClientImage.manifest(for:)` returns the first descriptor matching a
/// platform. BuildKit attestations are allowed to carry the same platform as
/// their subject, so platform-first lookup can return artifact metadata as a
/// Docker image config. This boundary classifies every descriptor once and
/// performs all content reads by digest instead.
struct RunnableImageSelector: Sendable {
    private let contentProvider: any RunnableImageContentProviding

    init(
        contentProvider: any RunnableImageContentProviding =
            LiveRunnableImageContentProvider()
    ) {
        self.contentProvider = contentProvider
    }

    func descriptors(for image: ClientImage) async throws
        -> [ResolvedImageDescriptor]
    {
        let index = try await contentProvider.index(for: image)
        let provider = contentProvider
        let graph = try await OCIImageGraphWalker.walk(
            rootIndex: index,
            loadIndex: { digest in
                try await provider.index(digest: digest)
            },
            loadManifest: { digest in
                try await provider.manifest(digest: digest)
            }
        )

        var resolved: [ResolvedImageDescriptor] = []
        var configsByDigest: [String: ContainerizationOCI.Image] = [:]
        var missingConfigDigests: Set<String> = []
        resolved.reserveCapacity(graph.entries.count)
        for entry in graph.entries {
            var runnableVariant: RunnableImageVariant?
            if entry.isRunnableCandidate,
                let manifest = entry.manifest,
                let platform = entry.descriptor.platform
            {
                let configDigest = manifest.config.digest
                let config: ContainerizationOCI.Image?
                if let cached = configsByDigest[configDigest] {
                    config = cached
                } else if missingConfigDigests.contains(configDigest) {
                    config = nil
                } else {
                    let loaded = try await contentProvider.config(
                        digest: configDigest
                    )
                    if let loaded {
                        configsByDigest[configDigest] = loaded
                    } else {
                        missingConfigDigests.insert(configDigest)
                    }
                    config = loaded
                }
                if let config {
                    runnableVariant = RunnableImageVariant(
                        descriptor: entry.descriptor,
                        platform: platform,
                        manifest: manifest,
                        config: config,
                        pathDepth: entry.pathDepth
                    )
                }
            }
            resolved.append(
                ResolvedImageDescriptor(
                    descriptor: entry.descriptor,
                    manifest: entry.manifest,
                    kind: entry.kind,
                    runnableVariant: runnableVariant,
                    artifactSubjectDigest: entry.artifactSubjectDigest,
                    pathDepth: entry.pathDepth,
                    documentAvailable: entry.documentAvailable,
                    runnableAncestorIndexDigests:
                        entry.runnableAncestorIndexDigests
                )
            )
        }
        return resolved
    }

    func selectVariant(
        from descriptors: [ResolvedImageDescriptor],
        requestedPlatform: Platform?,
        identityConstraint: RunnableImageIdentityConstraint = .unconstrained,
        hostPlatform: Platform = requestedOrDefaultPlatform(nil)
    ) -> RunnableImageVariant? {
        let variants = descriptors.compactMap {
            descriptor
                -> RunnableImageVariant? in
            guard let variant = descriptor.runnableVariant else {
                return nil
            }
            switch identityConstraint {
            case .unconstrained:
                return variant
            case .descendantOfIndex(let digest):
                return descriptor.runnableAncestorIndexDigests.contains(
                    digest
                ) ? variant : nil
            case .exactManifest(let manifestDigest, let configDigest):
                return descriptor.descriptor.digest == manifestDigest
                    && variant.manifest.config.digest == configDigest
                    ? variant : nil
            }
        }
        if let requestedPlatform {
            return
                variants
                .filter { $0.platform == requestedPlatform }
                .sorted(by: Self.stableVariantOrder)
                .first
        }

        return variants.sorted {
            let leftRank = Self.preferenceRank(
                $0.platform,
                preferred: hostPlatform
            )
            let rightRank = Self.preferenceRank(
                $1.platform,
                preferred: hostPlatform
            )
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            return Self.stableVariantOrder($0, $1)
        }.first
    }

    func descriptorsInDeterministicPreferenceOrder(
        _ descriptors: [ResolvedImageDescriptor],
        hostPlatform: Platform = requestedOrDefaultPlatform(nil)
    ) -> [ResolvedImageDescriptor] {
        descriptors.sorted { left, right in
            let leftRank =
                left.runnableVariant.map {
                    Self.preferenceRank($0.platform, preferred: hostPlatform)
                } ?? Int.max
            let rightRank =
                right.runnableVariant.map {
                    Self.preferenceRank($0.platform, preferred: hostPlatform)
                } ?? Int.max
            if leftRank != rightRank {
                return leftRank < rightRank
            }

            let leftPlatform =
                left.descriptor.platform.map(
                    Self.stablePlatformKey
                ) ?? ""
            let rightPlatform =
                right.descriptor.platform.map(
                    Self.stablePlatformKey
                ) ?? ""
            if leftPlatform != rightPlatform {
                return leftPlatform < rightPlatform
            }
            if left.pathDepth != right.pathDepth {
                return left.pathDepth < right.pathDepth
            }
            return left.descriptor.digest < right.descriptor.digest
        }
    }

    static func hasRunnablePlatform(_ platform: Platform?) -> Bool {
        guard let platform else { return false }
        let os = platform.os.trimmingCharacters(in: .whitespacesAndNewlines)
        let architecture = platform.architecture.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return !os.isEmpty && !architecture.isEmpty
            && os.lowercased() != "unknown"
            && architecture.lowercased() != "unknown"
    }

    static func isRunnable(
        descriptor: Descriptor,
        manifest: Manifest
    ) -> Bool {
        hasRunnablePlatform(descriptor.platform)
            && !hasArtifactSemantics(
                descriptor: descriptor,
                manifest: manifest
            )
    }

    static func dockerIdentityDigests(
        rootDigest: String,
        descriptors: [ResolvedImageDescriptor]
    ) -> Set<String> {
        Set(
            [rootDigest.lowercased()]
                + descriptors.flatMap(\.runnableAncestorIndexDigests)
                .map { $0.lowercased() }
                + descriptors.compactMap(\.runnableVariant).flatMap {
                    [$0.descriptor.digest.lowercased()]
                }
        )
    }

    static func hasArtifactSemantics(
        descriptor: Descriptor,
        manifest: Manifest?
    ) -> Bool {
        OCIArtifactSemantics.classify(
            descriptor: descriptor,
            manifest: manifest
        ).isArtifact
    }

    private static func preferenceRank(
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

    private static func stableVariantOrder(
        _ left: RunnableImageVariant,
        _ right: RunnableImageVariant
    ) -> Bool {
        let leftPlatform = stablePlatformKey(left.platform)
        let rightPlatform = stablePlatformKey(right.platform)
        if leftPlatform != rightPlatform {
            return leftPlatform < rightPlatform
        }
        if left.pathDepth != right.pathDepth {
            return left.pathDepth < right.pathDepth
        }
        return left.descriptor.digest < right.descriptor.digest
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
}
