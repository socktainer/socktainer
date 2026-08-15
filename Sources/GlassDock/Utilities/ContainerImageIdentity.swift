import ContainerAPIClient
import ContainerResource
import ContainerizationOCI

struct DockerContainerImageMetadata: Sendable, Equatable {
    let rootDigest: String
    let configDigest: String
    let displayReference: String
}

protocol ContainerImageMetadataProviding: Sendable {
    func metadata(for container: ContainerSnapshot) async -> DockerContainerImageMetadata
}

struct ImageStoreInventory: Sendable {
    let images: [ClientImage]
    let physicalReferencesByRootDigest: [String: Set<String>]
    let tagConfigSelections: [DockerTagConfigSelection]

    init(
        images: [ClientImage],
        physicalReferencesByRootDigest: [String: Set<String>],
        tagConfigSelections: [DockerTagConfigSelection] = []
    ) {
        self.images = images
        self.physicalReferencesByRootDigest = physicalReferencesByRootDigest
        self.tagConfigSelections = tagConfigSelections
    }
}

protocol ImageStoreInventoryProviding: Sendable {
    func imageStoreInventory(includeSystemImages: Bool) async throws -> ImageStoreInventory
}

/// Safe fallback for route-level tests and legacy construction sites. Production
/// injects `CanonicalContainerImageMetadataProvider` so moved/deleted tags are
/// checked against the shared image identity resolver.
struct StoredContainerImageMetadataProvider: ContainerImageMetadataProviding {
    func metadata(for container: ContainerSnapshot) async -> DockerContainerImageMetadata {
        let configDigest = await ContainerImageIdentity.configDigest(for: container)
        return DockerContainerImageMetadata(
            rootDigest: container.configuration.image.digest,
            configDigest: configDigest,
            displayReference: ContainerImageIdentity.requestedReference(
                for: container
            )
        )
    }
}

struct CanonicalContainerImageMetadataProvider: ContainerImageMetadataProviding {
    let resolver: any ImageReferenceResolving
    private let configDigestProvider: @Sendable (ContainerSnapshot) async -> String

    init(
        resolver: any ImageReferenceResolving,
        configDigestProvider: @escaping @Sendable (ContainerSnapshot) async -> String = {
            await ContainerImageIdentity.configDigest(for: $0)
        }
    ) {
        self.resolver = resolver
        self.configDigestProvider = configDigestProvider
    }

    func metadata(for container: ContainerSnapshot) async -> DockerContainerImageMetadata {
        let rootDigest = container.configuration.image.digest
        let configDigest = await configDigestProvider(container)
        return .init(
            rootDigest: rootDigest,
            configDigest: configDigest,
            displayReference: ContainerImageIdentity.requestedReference(
                for: container
            )
        )
    }
}

/// Joins immutable image roots retained by container snapshots with the current
/// Apple reference store. Tags are deliberately excluded from the join because
/// Docker permits a tag to move while old containers keep using the prior root.
enum ContainerImageIdentity {
    static let requestedReferenceLabel =
        "glassdock.image.requested-reference"
    static let configDigestLabel = "glassdock.image.config-digest"
    static let instanceOwnerLabel = "glassdock.instance.owner"

    static var reservedLabels: Set<String> {
        [requestedReferenceLabel, configDigestLabel, instanceOwnerLabel]
    }

    static func reservedUserLabel(
        in labels: [String: String]
    ) -> String? {
        labels.keys.sorted().first {
            reservedLabels.contains($0)
                || reservedLabels.contains(
                    LabelNormalization.sanitizeKey($0)
                )
        }
    }

    static func dockerLabels(
        for container: ContainerSnapshot
    ) -> [String: String] {
        dockerLabels(fromStored: container.configuration.labels)
    }

    static func dockerLabels(
        fromStored storedLabels: [String: String]
    ) -> [String: String] {
        var labels = LabelNormalization.restore(storedLabels)
        for reserved in reservedLabels {
            labels.removeValue(forKey: reserved)
        }
        return labels
    }

    static func storedRequestedReference(
        for container: ContainerSnapshot
    ) -> String? {
        container.configuration.labels[requestedReferenceLabel]
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static func requestedReference(
        for container: ContainerSnapshot
    ) -> String {
        storedRequestedReference(for: container)
            ?? container.configuration.image.reference
    }

    static func usageByRootDigest(_ containers: [ContainerSnapshot]) -> [String: Int] {
        Dictionary(grouping: containers, by: \.configuration.image.digest).mapValues(\.count)
    }

    static func containers(
        _ containers: [ContainerSnapshot],
        usingRootDigest rootDigest: String
    ) -> [ContainerSnapshot] {
        containers.filter { $0.configuration.image.digest == rootDigest }
    }

    static func matches(
        _ container: ContainerSnapshot,
        rootDigests: Set<String>,
        configDigest: String?,
        wholeRoot: Bool = false
    ) -> Bool {
        guard rootDigests.contains(container.configuration.image.digest) else {
            return false
        }
        guard !wholeRoot, let configDigest else { return true }
        guard
            let stored = container.configuration.labels[configDigestLabel],
            !stored.isEmpty
        else {
            // Pre-label snapshots cannot be safely distinguished inside a
            // multi-platform root, so retain the conservative root match.
            return true
        }
        return stored == configDigest
    }

    static func configDigest(
        for container: ContainerSnapshot,
        runnableImageSelector: RunnableImageSelector = RunnableImageSelector()
    ) async -> String {
        if let stored = container.configuration.labels[configDigestLabel],
            !stored.isEmpty
        {
            return stored
        }
        let image = ClientImage(description: container.configuration.image)
        guard
            let descriptors = try? await runnableImageSelector.descriptors(
                for: image
            )
        else {
            return container.configuration.image.digest
        }
        return runnableImageSelector.selectVariant(
            from: descriptors,
            requestedPlatform: container.configuration.platform
        )?.manifest.config.digest ?? container.configuration.image.digest
    }

    static func configDigest(
        for image: ClientImage,
        runnableImageSelector: RunnableImageSelector = RunnableImageSelector()
    ) async -> String {
        guard
            let descriptors = try? await runnableImageSelector.descriptors(
                for: image
            )
        else {
            return image.digest
        }
        return runnableImageSelector.selectVariant(
            from: descriptors,
            requestedPlatform: nil
        )?.manifest.config.digest ?? image.digest
    }

    /// Apple's disk-usage API accepts exact store keys rather than descriptors.
    /// Translate every in-use root through a physical inventory captured under
    /// the image mutation read lock, including hidden preservation references.
    static func activeStoreReferences(
        physicalReferencesByRootDigest: [String: Set<String>],
        containers: [ContainerSnapshot]
    ) -> Set<String> {
        let activeDigests = Set(containers.map(\.configuration.image.digest))
        return activeDigests.reduce(into: Set<String>()) { references, digest in
            references.formUnion(
                physicalReferencesByRootDigest[digest] ?? []
            )
        }
    }
}
