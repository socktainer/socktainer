import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Foundation

/// The kinds of OCI content Docker clients may send back as an image identifier.
enum ImageIdentityKind: Sendable, Equatable {
    case reference
    case root
    case manifest(Platform)
    case config(Platform)
}

struct ResolvedImageIdentity: Sendable {
    let image: ClientImage
    let reference: String
    let references: [String]
    let kind: ImageIdentityKind

    var impliedPlatform: Platform? {
        switch kind {
        case .manifest(let platform), .config(let platform): platform
        case .reference, .root: nil
        }
    }
}

enum ImageIdentityResolutionError: Error, Equatable {
    case notFound(String)
    case ambiguous(String)
    case nonRunnable(String)
}

protocol ImageIdentityCatalog: Sendable {
    func list() async throws -> [ClientImage]
    func index(for image: ClientImage) async throws -> Index
    func manifest(digest: String) async throws -> Manifest?
}

/// Narrow lookup boundary used by container ancestor filters. Keeping this
/// separate from the OCI catalog makes the filter path easy to test and avoids
/// teaching container filtering about index/manifest/config internals.
protocol ImageReferenceResolving: Sendable {
    func references(for identifier: String) async throws -> [String]
}

struct LiveImageIdentityCatalog: ImageIdentityCatalog {
    private let contentStore = RemoteContentStoreClient()

    func list() async throws -> [ClientImage] {
        try await ClientImage.list()
    }

    func index(for image: ClientImage) async throws -> Index {
        try await image.index()
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
    }

    private struct Record: Sendable {
        let image: ClientImage
        let references: [String]
        let rootDigest: String
        let variants: [Variant]
    }

    private struct Binding: Sendable {
        let rootDigest: String
        let kind: ImageIdentityKind
    }

    private struct AliasBinding: Sendable {
        let rootDigest: String
        let reference: String
    }

    private struct AliasSet: Sendable {
        var priority: Int
        var bindings: [AliasBinding]
    }

    private struct Snapshot: Sendable {
        var aliases: [String: AliasSet] = [:]
        var records: [String: Record] = [:]
        var digests: [String: [Binding]] = [:]
        var artifactDigests: Set<String> = []
        var sortedDigests: [String] = []
    }

    private let systemConfig: ContainerSystemConfig
    private let catalog: any ImageIdentityCatalog
    private let stateURL: URL
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
        appSupportURL: URL? = nil
    ) {
        self.systemConfig = systemConfig
        self.catalog = catalog
        self.stateURL = (appSupportURL ?? Self.defaultAppSupportURL()).appendingPathComponent("state.json")
    }

    func refresh() async throws {
        while true {
            let refresh: InFlightRefresh
            if let existing = inFlightRefresh {
                refresh = existing
            } else {
                let id = UUID()
                let initialRevision = currentStoreRevision()
                let catalog = catalog
                let systemConfig = systemConfig
                let task = Task {
                    try await Self.buildSnapshot(catalog: catalog, systemConfig: systemConfig)
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
        systemConfig: ContainerSystemConfig
    ) async throws -> Snapshot {
        let images = try await catalog.list()
        var grouped: [String: [ClientImage]] = [:]
        for image in images {
            grouped[image.digest, default: []].append(image)
        }

        var next = Snapshot()
        for rootDigest in grouped.keys.sorted() {
            guard let groupedImages = grouped[rootDigest] else { continue }
            let orderedImages = groupedImages.sorted { $0.reference < $1.reference }
            guard let representative = orderedImages.first else { continue }
            let references = orderedImages.map(\.reference)
            let index = try await catalog.index(for: representative)
            var variants: [Variant] = []

            for descriptor in index.manifests {
                guard let manifest = try await catalog.manifest(digest: descriptor.digest) else {
                    continue
                }
                if Self.isArtifact(descriptor: descriptor, manifest: manifest) {
                    next.artifactDigests.insert(Self.canonicalDigest(descriptor.digest))
                    next.artifactDigests.insert(Self.canonicalDigest(manifest.config.digest))
                    continue
                }
                guard let platform = descriptor.platform else { continue }
                variants.append(
                    Variant(
                        platform: platform,
                        manifestDigest: Self.canonicalDigest(descriptor.digest),
                        configDigest: Self.canonicalDigest(manifest.config.digest)
                    ))
            }

            let record = Record(
                image: representative,
                references: references,
                rootDigest: Self.canonicalDigest(rootDigest),
                variants: variants
            )
            next.records[record.rootDigest] = record
            next.digests[record.rootDigest, default: []].append(
                Binding(rootDigest: record.rootDigest, kind: .root))

            for image in orderedImages {
                Self.addReferenceAliases(
                    image.reference,
                    storedReference: image.reference,
                    rootDigest: record.rootDigest,
                    systemConfig: systemConfig,
                    priority: 1,
                    to: &next.aliases
                )
                let annotations = image.descriptor.annotations ?? [:]
                let annotatedName =
                    annotations[AnnotationKeys.containerizationImageName]
                    ?? annotations[AnnotationKeys.containerdImageName]
                    ?? annotations[AnnotationKeys.openContainersImageName]
                if let annotatedName {
                    Self.addReferenceAliases(
                        annotatedName,
                        storedReference: image.reference,
                        rootDigest: record.rootDigest,
                        systemConfig: systemConfig,
                        priority: 0,
                        to: &next.aliases
                    )
                }
            }
            for variant in variants {
                next.digests[variant.manifestDigest, default: []].append(
                    Binding(rootDigest: record.rootDigest, kind: .manifest(variant.platform)))
                next.digests[variant.configDigest, default: []].append(
                    Binding(rootDigest: record.rootDigest, kind: .config(variant.platform)))
            }
        }
        next.sortedDigests = next.digests.keys.sorted()
        return next
    }

    func resolve(_ input: String) async throws -> ResolvedImageIdentity {
        if !loaded || storeRevision != currentStoreRevision() {
            try await refresh()
        }

        if let aliases = snapshot.aliases[input] ?? normalizedAlias(input).flatMap({ snapshot.aliases[$0] }) {
            let roots = Set(aliases.bindings.map(\.rootDigest))
            guard roots.count == 1, let alias = aliases.bindings.first,
                let record = snapshot.records[alias.rootDigest]
            else {
                throw ImageIdentityResolutionError.ambiguous(input)
            }
            return resolved(record: record, kind: .reference, reference: alias.reference)
        }

        if let scoped = scopedDigest(input) {
            let bindings = snapshot.digests[Self.canonicalDigest(scoped.digest)] ?? []
            let matching = bindings.filter { binding in
                guard let record = snapshot.records[binding.rootDigest] else { return false }
                return record.references.contains { Self.repository(of: $0) == scoped.repository }
            }
            return try resolveBindings(matching, input: input)
        }

        guard let prefix = Self.digestPrefix(input) else {
            throw ImageIdentityResolutionError.notFound(input)
        }
        let canonical = "sha256:\(prefix)"
        if prefix.count == 64 {
            if snapshot.artifactDigests.contains(canonical) {
                throw ImageIdentityResolutionError.nonRunnable(input)
            }
            return try resolveBindings(snapshot.digests[canonical] ?? [], input: input)
        }

        var bindings: [Binding] = []
        var index = Self.lowerBound(snapshot.sortedDigests, canonical)
        while index < snapshot.sortedDigests.count {
            let digest = snapshot.sortedDigests[index]
            guard digest.hasPrefix(canonical) else { break }
            bindings.append(contentsOf: snapshot.digests[digest] ?? [])
            index += 1
        }
        return try resolveBindings(bindings, input: input)
    }

    private func resolveBindings(_ bindings: [Binding], input: String) throws -> ResolvedImageIdentity {
        let roots = Set(bindings.map(\.rootDigest))
        guard !roots.isEmpty else {
            throw ImageIdentityResolutionError.notFound(input)
        }
        guard roots.count == 1, let root = roots.first, let record = snapshot.records[root] else {
            throw ImageIdentityResolutionError.ambiguous(input)
        }

        let candidates = bindings.filter { $0.rootDigest == root }
        let kind = candidates.sorted { Self.kindRank($0.kind) < Self.kindRank($1.kind) }.first?.kind ?? .root
        return resolved(record: record, kind: kind)
    }

    private func resolved(record: Record, kind: ImageIdentityKind, reference: String? = nil) -> ResolvedImageIdentity {
        let resolvedReference = reference ?? record.image.reference
        let image = ClientImage(
            description: ImageDescription(
                reference: resolvedReference,
                descriptor: record.image.descriptor
            ))
        return ResolvedImageIdentity(
            image: image,
            reference: resolvedReference,
            references: record.references,
            kind: kind
        )
    }

    private func normalizedAlias(_ input: String) -> String? {
        try? ClientImage.normalizeReference(input, containerSystemConfig: systemConfig)
    }

    private static func addReferenceAliases(
        _ reference: String,
        storedReference: String,
        rootDigest: String,
        systemConfig: ContainerSystemConfig,
        priority: Int,
        to aliases: inout [String: AliasSet]
    ) {
        let binding = AliasBinding(rootDigest: rootDigest, reference: storedReference)
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
            $0.rootDigest == binding.rootDigest && $0.reference == binding.reference
        }) {
            existing.bindings.append(binding)
            aliases[alias] = existing
        }
    }

    private static func isArtifact(descriptor: Descriptor, manifest: Manifest) -> Bool {
        if descriptor.annotations?["vnd.docker.reference.type"] == "attestation-manifest" {
            return true
        }
        if descriptor.artifactType != nil || manifest.artifactType != nil || manifest.subject != nil {
            return true
        }
        guard let platform = descriptor.platform else { return true }
        return platform.os == "unknown" || platform.architecture == "unknown"
    }

    private static func repository(of reference: String) -> String? {
        (try? Reference.parse(reference))?.name
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
    func references(for identifier: String) async throws -> [String] {
        try await resolve(identifier).references
    }
}
