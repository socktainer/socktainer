import ContainerizationOCI
import Foundation
import Logging

/// `docker save` (v25+) writes an OCI layout whose index blob preserves the
/// image's original multi-platform index — every platform and attestation
/// manifest digest — while only including blobs for the platform the engine
/// had. Apple's `ImageStore.load` resolves an index strictly and fails on the
/// first absent manifest, so the layout is pruned down to what the tarball
/// actually contains before loading.
enum OCILayoutPruner {
    struct ArtifactMetadata: Sendable, Equatable {
        let isArtifact: Bool
        let subjectDigest: String?
    }

    enum PruneError: Error, LocalizedError, Equatable {
        case nothingLoadable
        case indexNestingTooDeep

        var errorDescription: String? {
            switch self {
            case .nothingLoadable:
                return "the tarball contains no image manifest with complete content for any platform"
            case .indexNestingTooDeep:
                return "the tarball nests image indexes beyond the supported depth"
            }
        }
    }

    static func pruneManifestsWithMissingBlobs(
        at layout: URL,
        platform: Platform? = nil,
        logger: Logger
    ) throws {
        let indexURL = layout.appendingPathComponent("index.json")
        var index = try JSONDecoder().decode(
            Index.self,
            from: BoundedFileReader.readImageMetadata(
                relativePath: "index.json",
                under: layout
            )
        )
        let originalDescriptors = index.manifests

        let cache = PruneCache()
        index.manifests = try index.manifests.compactMap {
            try prunedDescriptor(
                $0,
                in: layout,
                selectedPlatform: platform,
                cache: cache,
                logger: logger
            )
        }
        index.manifests = try filterAttestations(
            index.manifests,
            selectedPlatform: platform,
            in: layout
        )

        guard !index.manifests.isEmpty else {
            throw PruneError.nothingLoadable
        }
        if index.manifests != originalDescriptors {
            try JSONEncoder().encode(index).write(to: indexURL)
        }
    }

    /// Returns the descriptor to keep for `descriptor`, rewriting an index down to the
    /// manifests whose content is present (recursively, so a partially-present nested
    /// index keeps its loadable platforms), or nil when nothing under it is loadable.
    ///
    /// A real `docker save` nests one index level; beyond this the tarball is rejected.
    /// The cap bounds recursion against a crafted chain of distinct nested indexes —
    /// which neither the cycle guard (all digests differ) nor the cache (each visited
    /// once) would otherwise stop before a stack overflow. It aborts rather than drops
    /// the branch so a result stays independent of the depth it was first reached at,
    /// keeping the digest-keyed cache correct.
    private static let maxIndexNestingDepth = 32

    /// Rewrites an Apple-exported OCI index so each top-level reference retains
    /// the exact Docker identity selected before export. Apple's save API can
    /// filter only by platform; it cannot distinguish sibling manifests for the
    /// same platform or a nested index selected by digest.
    static func selectExactIdentities(
        at layout: URL,
        constraints: [RunnableImageIdentityConstraint],
        platform: Platform?,
        logger: Logger
    ) throws {
        let indexURL = layout.appendingPathComponent("index.json")
        var index = try JSONDecoder().decode(
            Index.self,
            from: BoundedFileReader.readImageMetadata(
                relativePath: "index.json",
                under: layout
            )
        )
        guard index.manifests.count == constraints.count else {
            throw PruneError.nothingLoadable
        }
        let cache = PruneCache()
        index.manifests = try zip(index.manifests, constraints).map {
            root, constraint in
            let selected: Descriptor?
            switch constraint {
            case .unconstrained:
                selected = try prunedDescriptor(
                    root,
                    in: layout,
                    selectedPlatform: platform,
                    cache: cache,
                    logger: logger
                )
            case .descendantOfIndex(let digest):
                let nested = try findDescriptor(
                    digest: digest,
                    beneath: root,
                    in: layout
                ) { isIndex($0.mediaType) }
                if let nested, platform != nil {
                    selected = try prunedDescriptor(
                        nested,
                        in: layout,
                        selectedPlatform: platform,
                        cache: cache,
                        logger: logger
                    )
                } else {
                    selected = nested
                }
            case .exactManifest(let manifestDigest, let configDigest):
                selected = try findDescriptor(
                    digest: manifestDigest,
                    beneath: root,
                    in: layout
                ) { descriptor in
                    guard isManifest(descriptor.mediaType),
                        let manifest = try? JSONDecoder().decode(
                            Manifest.self,
                            from: readBlobMetadata(
                                descriptor.digest,
                                in: layout
                            )
                        )
                    else { return false }
                    return manifest.config.digest.lowercased()
                        == configDigest.lowercased()
                }
            }
            guard var selected else { throw PruneError.nothingLoadable }
            if let platform,
                case .exactManifest = constraint,
                selected.platform != platform
            {
                throw PruneError.nothingLoadable
            }
            var annotations = selected.annotations ?? [:]
            for (key, value) in root.annotations ?? [:] {
                annotations[key] = value
            }
            selected.annotations = annotations.isEmpty ? nil : annotations
            return selected
        }
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }

    private static func findDescriptor(
        digest: String,
        beneath root: Descriptor,
        in layout: URL,
        depth: Int = 0,
        visiting: Set<String> = [],
        accepts: (Descriptor) -> Bool
    ) throws -> Descriptor? {
        guard depth <= maxIndexNestingDepth else {
            throw PruneError.indexNestingTooDeep
        }
        if root.digest.lowercased() == digest.lowercased(), accepts(root) {
            return root
        }
        guard isIndex(root.mediaType),
            !visiting.contains(root.digest),
            let index = try? JSONDecoder().decode(
                Index.self,
                from: readBlobMetadata(root.digest, in: layout)
            )
        else { return nil }
        for child in index.manifests {
            if let found = try findDescriptor(
                digest: digest,
                beneath: child,
                in: layout,
                depth: depth + 1,
                visiting: visiting.union([root.digest]),
                accepts: accepts
            ) {
                return found
            }
        }
        return nil
    }

    /// Blob content is never re-hashed against its digest, so a crafted tarball can make
    /// an index reference itself (a cycle) or fan out to the same sub-index exponentially.
    /// The path guard cuts cycles; the cache collapses repeated sub-indexes to one visit.
    private static func prunedDescriptor(
        _ descriptor: Descriptor,
        in layout: URL,
        selectedPlatform: Platform?,
        depth: Int = 0,
        visiting: Set<String> = [],
        cache: PruneCache,
        logger: Logger
    ) throws
        -> Descriptor?
    {
        guard depth <= maxIndexNestingDepth else { throw PruneError.indexNestingTooDeep }
        if isIndex(descriptor.mediaType), visiting.contains(descriptor.digest) {
            return nil
        }
        // Keyed by media type too: the same bytes are validated differently as an index
        // vs a manifest, and blobs are never re-hashed, so one digest can carry both.
        let selectionKey = selectionCacheKey(
            descriptor: descriptor,
            selectedPlatform: selectedPlatform,
            remainingDepth: maxIndexNestingDepth - depth
        )
        switch cache.lookup(
            digest: descriptor.digest,
            mediaType: descriptor.mediaType,
            selectionKey: selectionKey,
            keeping: descriptor
        ) {
        case .resolved(let cached):
            return cached
        case .unresolved:
            break
        }

        guard blobExists(descriptor.digest, in: layout) else {
            cache.store(
                nil,
                digest: descriptor.digest,
                mediaType: descriptor.mediaType,
                selectionKey: selectionKey
            )
            return nil
        }

        let result: Descriptor?
        if isManifest(descriptor.mediaType) {
            guard
                let manifest = try? JSONDecoder().decode(
                    Manifest.self,
                    from: readBlobMetadata(descriptor.digest, in: layout)
                )
            else {
                cache.store(
                    nil,
                    digest: descriptor.digest,
                    mediaType: descriptor.mediaType,
                    selectionKey: selectionKey
                )
                return nil
            }
            let complete =
                blobExists(manifest.config.digest, in: layout)
                && manifest.layers.allSatisfy {
                    blobExists($0.digest, in: layout)
                }
            guard complete else {
                cache.store(
                    nil,
                    digest: descriptor.digest,
                    mediaType: descriptor.mediaType,
                    selectionKey: selectionKey
                )
                return nil
            }
            let artifact = artifactMetadata(
                for: descriptor,
                manifest: manifest
            )
            if let selectedPlatform, !artifact.isArtifact {
                result =
                    descriptor.platform == selectedPlatform
                    ? descriptor : nil
            } else {
                result = descriptor
            }
        } else if isIndex(descriptor.mediaType) {
            guard
                var childIndex = try? JSONDecoder().decode(
                    Index.self,
                    from: readBlobMetadata(descriptor.digest, in: layout)
                )
            else {
                cache.store(
                    nil,
                    digest: descriptor.digest,
                    mediaType: descriptor.mediaType,
                    selectionKey: selectionKey
                )
                return nil
            }
            var pruned: [Descriptor] = []
            pruned.reserveCapacity(childIndex.manifests.count)
            let nextVisiting = visiting.union([descriptor.digest])
            for child in childIndex.manifests {
                if let kept = try prunedDescriptor(
                    child,
                    in: layout,
                    selectedPlatform: selectedPlatform,
                    depth: depth + 1,
                    visiting: nextVisiting,
                    cache: cache,
                    logger: logger
                ) {
                    pruned.append(kept)
                }
            }
            let selected = try filterAttestations(
                pruned,
                selectedPlatform: selectedPlatform,
                in: layout
            )
            if selected.isEmpty {
                result = nil
            } else if selected == childIndex.manifests {
                result = descriptor
            } else {
                childIndex.manifests = selected
                result = try rewrittenIndex(
                    childIndex,
                    keeping: descriptor,
                    in: layout,
                    logger: logger
                )
            }
        } else {
            result = descriptor
        }

        cache.store(
            result,
            digest: descriptor.digest,
            mediaType: descriptor.mediaType,
            selectionKey: selectionKey
        )
        return result
    }

    private static func rewrittenIndex(_ childIndex: Index, keeping original: Descriptor, in layout: URL, logger: Logger) throws -> Descriptor {
        // This byte sequence is content-addressed. Foundation dictionary order
        // is process-randomized, so an ordinary encoder can assign a different
        // root digest to the same logical pruned index after daemon restart.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(childIndex)
        let digest = "sha256:" + data.sha256Hex()
        try data.write(to: blobURL(digest, in: layout))
        logger.info("pruned index \(original.digest) -> \(digest): kept \(childIndex.manifests.count) manifest(s)")
        return Descriptor(
            mediaType: original.mediaType,
            digest: digest,
            size: Int64(data.count),
            urls: original.urls,
            annotations: original.annotations,
            platform: original.platform,
            artifactType: original.artifactType
        )
    }

    private final class PruneCache {
        enum Lookup {
            case unresolved
            case resolved(Descriptor?)
        }

        private struct Key: Hashable {
            let digest: String
            let mediaType: String
            let selectionKey: String
        }

        private struct ContentDescriptor {
            let mediaType: String
            let digest: String
            let size: Int64

            func applyingMetadata(from descriptor: Descriptor) -> Descriptor {
                Descriptor(
                    mediaType: mediaType,
                    digest: digest,
                    size: size,
                    urls: descriptor.urls,
                    annotations: descriptor.annotations,
                    platform: descriptor.platform,
                    artifactType: descriptor.artifactType
                )
            }
        }

        private enum Entry {
            case missing
            case present(ContentDescriptor)
        }

        private var resolved: [Key: Entry] = [:]

        func lookup(
            digest: String,
            mediaType: String,
            selectionKey: String,
            keeping descriptor: Descriptor
        ) -> Lookup {
            let key = Key(
                digest: digest,
                mediaType: mediaType,
                selectionKey: selectionKey
            )
            guard let known = resolved[key] else { return .unresolved }
            switch known {
            case .missing:
                return .resolved(nil)
            case .present(let content):
                return .resolved(content.applyingMetadata(from: descriptor))
            }
        }

        func store(
            _ value: Descriptor?,
            digest: String,
            mediaType: String,
            selectionKey: String
        ) {
            let key = Key(
                digest: digest,
                mediaType: mediaType,
                selectionKey: selectionKey
            )
            guard let value else {
                resolved[key] = .missing
                return
            }
            let content = ContentDescriptor(
                mediaType: value.mediaType,
                digest: value.digest,
                size: value.size
            )
            resolved[key] = .present(content)
        }
    }

    private static func isIndex(_ mediaType: String) -> Bool {
        mediaType == MediaTypes.index || mediaType == MediaTypes.dockerManifestList
    }

    private static func isManifest(_ mediaType: String) -> Bool {
        mediaType == MediaTypes.imageManifest || mediaType == MediaTypes.dockerManifest
    }

    private static func selectionCacheKey(
        descriptor: Descriptor,
        selectedPlatform: Platform?,
        remainingDepth: Int
    ) -> String {
        let descriptorArtifact = OCIArtifactSemantics.classify(
            descriptor: descriptor
        )
        return [
            platformCacheKey(selectedPlatform),
            platformCacheKey(descriptor.platform),
            descriptorArtifact.isArtifact ? "artifact" : "image",
            String(remainingDepth),
        ].joined(separator: "\u{0}")
    }

    private static func platformCacheKey(_ platform: Platform?) -> String {
        guard let platform else { return "" }
        return [
            platform.os,
            platform.architecture,
            platform.variant ?? "",
            platform.osVersion ?? "",
            (platform.osFeatures ?? []).sorted().joined(separator: ","),
        ].joined(separator: "\u{1}")
    }

    static func artifactMetadata(
        for descriptor: Descriptor,
        in layout: URL
    ) throws -> ArtifactMetadata {
        if isManifest(descriptor.mediaType) {
            let manifest = try JSONDecoder().decode(
                Manifest.self,
                from: readBlobMetadata(descriptor.digest, in: layout)
            )
            return artifactMetadata(for: descriptor, manifest: manifest)
        }
        if isIndex(descriptor.mediaType) {
            let index = try JSONDecoder().decode(
                Index.self,
                from: readBlobMetadata(descriptor.digest, in: layout)
            )
            let classification = OCIArtifactSemantics.classify(
                descriptor: descriptor,
                index: index
            )
            return ArtifactMetadata(
                isArtifact: classification.isArtifact,
                subjectDigest: classification.subjectDigest
            )
        }
        let classification = OCIArtifactSemantics.classify(
            descriptor: descriptor
        )
        return ArtifactMetadata(
            isArtifact: classification.isArtifact,
            subjectDigest: classification.subjectDigest
        )
    }

    private static func artifactMetadata(
        for descriptor: Descriptor,
        manifest: Manifest
    ) -> ArtifactMetadata {
        let classification = OCIArtifactSemantics.classify(
            descriptor: descriptor,
            manifest: manifest
        )
        return ArtifactMetadata(
            isArtifact: classification.isArtifact,
            subjectDigest: classification.subjectDigest
        )
    }

    private static func artifactMetadata(
        for descriptor: Descriptor,
        index: Index
    ) -> ArtifactMetadata {
        let classification = OCIArtifactSemantics.classify(
            descriptor: descriptor,
            index: index
        )
        return ArtifactMetadata(
            isArtifact: classification.isArtifact,
            subjectDigest: classification.subjectDigest
        )
    }

    /// Proves that an archive-local descriptor graph represents at least one
    /// runnable image and that every attached artifact names a runnable subject
    /// within that graph. This is deliberately recursive: an index document is
    /// not runnable merely because its descriptor itself lacks artifact fields.
    ///
    /// Archive traversal is content-addressed and bounded. The memo key includes
    /// the remaining depth and descriptor-level artifact semantics because OCI
    /// permits the same document digest to appear with different descriptor
    /// annotations. Cycle-dependent partial results are never cached.
    static func containsCoherentRunnableImage(
        for descriptor: Descriptor,
        in layout: URL
    ) throws -> Bool {
        let result = try imageGraphMetadata(
            for: descriptor,
            in: layout,
            cache: ImageGraphCache()
        )
        guard !result.runnableDigests.isEmpty else { return false }
        return result.artifactSubjects.allSatisfy { subject in
            guard let subject else { return false }
            return result.runnableDigests.contains(subject)
        }
    }

    private struct ImageGraphResult {
        var runnableDigests: Set<String> = []
        var artifactSubjects: Set<String?> = []
        var encounteredCycle = false

        mutating func merge(_ other: ImageGraphResult) {
            runnableDigests.formUnion(other.runnableDigests)
            artifactSubjects.formUnion(other.artifactSubjects)
            encounteredCycle = encounteredCycle || other.encounteredCycle
        }
    }

    private final class ImageGraphCache {
        struct Key: Hashable {
            let digest: String
            let mediaType: String
            let isArtifact: Bool
            let subjectDigest: String?
            let hasRunnablePlatform: Bool
            let remainingDepth: Int
        }

        var values: [Key: ImageGraphResult] = [:]
    }

    private static func imageGraphMetadata(
        for descriptor: Descriptor,
        in layout: URL,
        depth: Int = 0,
        visiting: Set<String> = [],
        cache: ImageGraphCache
    ) throws -> ImageGraphResult {
        guard depth <= maxIndexNestingDepth else {
            throw PruneError.indexNestingTooDeep
        }
        guard blobExists(descriptor.digest, in: layout) else {
            return ImageGraphResult()
        }

        if isManifest(descriptor.mediaType) {
            guard
                let manifest = try? JSONDecoder().decode(
                    Manifest.self,
                    from: readBlobMetadata(descriptor.digest, in: layout)
                )
            else {
                return ImageGraphResult()
            }
            let metadata = artifactMetadata(
                for: descriptor,
                manifest: manifest
            )
            let key = ImageGraphCache.Key(
                digest: descriptor.digest,
                mediaType: descriptor.mediaType,
                isArtifact: metadata.isArtifact,
                subjectDigest: metadata.subjectDigest,
                hasRunnablePlatform:
                    RunnableImageSelector
                    .hasRunnablePlatform(descriptor.platform),
                remainingDepth: maxIndexNestingDepth - depth
            )
            if let cached = cache.values[key] { return cached }

            var result = ImageGraphResult()
            if metadata.isArtifact {
                result.artifactSubjects.insert(metadata.subjectDigest)
            } else if RunnableImageSelector.hasRunnablePlatform(
                descriptor.platform
            ), blobExists(manifest.config.digest, in: layout),
                manifest.layers.allSatisfy({ blobExists($0.digest, in: layout) })
            {
                result.runnableDigests.insert(descriptor.digest)
            }
            cache.values[key] = result
            return result
        }

        if isIndex(descriptor.mediaType) {
            guard !visiting.contains(descriptor.digest) else {
                return ImageGraphResult(encounteredCycle: true)
            }
            guard
                let index = try? JSONDecoder().decode(
                    Index.self,
                    from: readBlobMetadata(descriptor.digest, in: layout)
                )
            else {
                return ImageGraphResult()
            }
            let metadata = artifactMetadata(
                for: descriptor,
                index: index
            )
            let key = ImageGraphCache.Key(
                digest: descriptor.digest,
                mediaType: descriptor.mediaType,
                isArtifact: metadata.isArtifact,
                subjectDigest: metadata.subjectDigest,
                hasRunnablePlatform:
                    RunnableImageSelector
                    .hasRunnablePlatform(descriptor.platform),
                remainingDepth: maxIndexNestingDepth - depth
            )
            if let cached = cache.values[key] { return cached }

            if metadata.isArtifact {
                let result = ImageGraphResult(
                    artifactSubjects: Set([metadata.subjectDigest])
                )
                cache.values[key] = result
                return result
            }

            var result = ImageGraphResult()
            for child in index.manifests {
                result.merge(
                    try imageGraphMetadata(
                        for: child,
                        in: layout,
                        depth: depth + 1,
                        visiting: visiting.union([descriptor.digest]),
                        cache: cache
                    )
                )
            }
            if !result.runnableDigests.isEmpty {
                result.runnableDigests.insert(descriptor.digest)
            }
            if !result.encounteredCycle {
                cache.values[key] = result
            }
            return result
        }

        return ImageGraphResult()
    }

    /// BuildKit attaches provenance/SBOM manifests to the selected runnable
    /// manifest. When Docker requests one platform, keep only attestations whose
    /// subject remains in the pruned index; a full load keeps every complete
    /// attestation.
    private static func filterAttestations(
        _ descriptors: [Descriptor],
        selectedPlatform: Platform?,
        in layout: URL
    ) throws -> [Descriptor] {
        let metadata = try descriptors.map {
            ($0, try artifactMetadata(for: $0, in: layout))
        }
        let runnableDigests = Set(
            metadata.filter { !$0.1.isArtifact }.map { $0.0.digest }
        )
        let kept = metadata.filter { _, artifact in
            guard artifact.isArtifact, selectedPlatform != nil else {
                return true
            }
            guard let subject = artifact.subjectDigest else { return false }
            return runnableDigests.contains(subject)
        }
        // Apple selects platform content by first match. Preserve relative
        // order inside each class while placing runnable descriptors before
        // same-platform OCI subjects/attestations.
        return kept.filter { !$0.1.isArtifact }.map(\.0)
            + kept.filter { $0.1.isArtifact }.map(\.0)
    }

    /// Digests come from attacker-suppliable tarball JSON and are spliced into
    /// filesystem paths — anything but `algorithm:hex` addressing a regular file is
    /// treated as absent (a digest-named directory is not a blob).
    private static func blobExists(_ digest: String, in layout: URL) -> Bool {
        guard isWellFormedDigest(digest) else { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: blobURL(digest, in: layout).path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    private static func isWellFormedDigest(_ digest: String) -> Bool {
        let components = digest.utf8.split(
            separator: 58,
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
            !components[0].isEmpty,
            components[1].count >= 32
        else {
            return false
        }
        let algorithmIsSafe = components[0].allSatisfy {
            ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57)
        }
        let digestIsHex = components[1].allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 97 && $0 <= 102)
                || ($0 >= 65 && $0 <= 70)
        }
        return algorithmIsSafe && digestIsHex
    }

    private static func blobURL(_ digest: String, in layout: URL) -> URL {
        let components = digest.split(separator: ":")
        let algorithm = components.count == 2 ? String(components[0]) : "sha256"
        let hex = components.count == 2 ? String(components[1]) : digest
        return layout.appendingPathComponent("blobs").appendingPathComponent(algorithm).appendingPathComponent(hex)
    }

    private static func readBlobMetadata(
        _ digest: String,
        in layout: URL
    ) throws -> Data {
        guard isWellFormedDigest(digest) else {
            throw BoundedFileReadError.invalidRelativePath(digest)
        }
        let components = digest.split(separator: ":", maxSplits: 1)
        return try BoundedFileReader.readImageMetadata(
            relativePath: "blobs/\(components[0])/\(components[1])",
            under: layout
        )
    }
}
