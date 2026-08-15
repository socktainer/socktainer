import ContainerizationOCI
import Foundation
import Logging
import Testing

@testable import GlassDock

@Suite("OCILayoutPruner")
struct OCILayoutPrunerTests {

    @Test("a docker-save layout with only one platform's blobs is pruned to that platform")
    func prunesAbsentPlatformManifests() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let arm64Manifest = try layout.writePresentManifest(platform: Platform(arch: "arm64", os: "linux"))
        let amd64Manifest = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: "sha256:" + String(repeating: "a", count: 64),
            size: 500,
            platform: Platform(arch: "amd64", os: "linux")
        )
        let originalIndexDescriptor = try layout.writeIndexBlob(
            manifests: [arm64Manifest, amd64Manifest],
            annotations: ["io.containerd.image.name": "docker.io/library/alpine:3.21"]
        )
        try layout.writeTopIndex(manifests: [originalIndexDescriptor])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let top = try layout.readTopIndex()
        #expect(top.manifests.count == 1)
        let rewritten = try #require(top.manifests.first)
        #expect(rewritten.digest != originalIndexDescriptor.digest)
        #expect(rewritten.annotations?["io.containerd.image.name"] == "docker.io/library/alpine:3.21")

        let rewrittenIndex = try layout.readIndexBlob(digest: rewritten.digest)
        #expect(rewrittenIndex.manifests.map(\.digest) == [arm64Manifest.digest])
        #expect(Int64(try layout.blobData(digest: rewritten.digest).count) == rewritten.size)
    }

    @Test("a layout whose blobs are all present is left byte-identical")
    func leavesCompleteLayoutUntouched() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let manifest = try layout.writePresentManifest(platform: Platform(arch: "arm64", os: "linux"))
        let indexDescriptor = try layout.writeIndexBlob(manifests: [manifest], annotations: nil)
        try layout.writeTopIndex(manifests: [indexDescriptor])
        let before = try Data(contentsOf: layout.root.appendingPathComponent("index.json"))

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let after = try Data(contentsOf: layout.root.appendingPathComponent("index.json"))
        #expect(before == after)
    }

    @Test("a manifest whose layer blob is missing counts as absent")
    func manifestWithMissingLayerIsDropped() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let broken = try layout.writeManifestMissingLayer(platform: Platform(arch: "arm64", os: "linux"))
        let intact = try layout.writePresentManifest(platform: Platform(arch: "riscv64", os: "linux"))
        let indexDescriptor = try layout.writeIndexBlob(manifests: [broken, intact], annotations: nil)
        try layout.writeTopIndex(manifests: [indexDescriptor])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let top = try layout.readTopIndex()
        let rewrittenIndex = try layout.readIndexBlob(digest: top.manifests[0].digest)
        #expect(rewrittenIndex.manifests.map(\.digest) == [intact.digest])
    }

    @Test("a nested index with some present manifests is pruned to them, not dropped")
    func partialNestedIndexIsPrunedNotDropped() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let present = try layout.writePresentManifest(platform: Platform(arch: "arm64", os: "linux"))
        let missing = Descriptor(
            mediaType: MediaTypes.imageManifest, digest: "sha256:" + String(repeating: "a", count: 64), size: 500,
            platform: Platform(arch: "amd64", os: "linux"))
        let inner = try layout.writeIndexBlob(manifests: [present, missing], annotations: nil)
        let outer = try layout.writeIndexBlob(manifests: [inner], annotations: nil)
        try layout.writeTopIndex(manifests: [outer])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let top = try layout.readTopIndex()
        let outerPruned = try layout.readIndexBlob(digest: top.manifests[0].digest)
        let innerPruned = try layout.readIndexBlob(digest: outerPruned.manifests[0].digest)
        #expect(innerPruned.manifests.map(\.digest) == [present.digest])
    }

    @Test("rewritten index bytes and digests are deterministic across annotation order")
    func rewrittenIndexesAreDeterministic() throws {
        let first = try LayoutFixture()
        let second = try LayoutFixture()
        defer {
            first.cleanUp()
            second.cleanUp()
        }

        var firstAnnotations: [String: String] = [:]
        firstAnnotations["zeta"] = "last"
        firstAnnotations["alpha"] = "first"
        var secondAnnotations: [String: String] = [:]
        secondAnnotations["alpha"] = "first"
        secondAnnotations["zeta"] = "last"

        for (layout, annotations) in [
            (first, firstAnnotations),
            (second, secondAnnotations),
        ] {
            let present = try layout.writePresentManifest(
                platform: Platform(arch: "arm64", os: "linux")
            )
            let missing = Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: "sha256:" + String(repeating: "f", count: 64),
                size: 500,
                platform: Platform(arch: "amd64", os: "linux")
            )
            let child = try layout.writeIndexBlob(
                manifests: [present, missing],
                annotations: ["io.containerd.image.name": "example:latest"],
                indexAnnotations: annotations
            )
            try layout.writeTopIndex(manifests: [child])
            try OCILayoutPruner.pruneManifestsWithMissingBlobs(
                at: layout.root,
                logger: Logger(label: "test")
            )
        }

        let firstDigest = try #require(first.readTopIndex().manifests.first?.digest)
        let secondDigest = try #require(second.readTopIndex().manifests.first?.digest)
        #expect(firstDigest == secondDigest)
        #expect(
            try first.blobData(digest: firstDigest)
                == second.blobData(digest: secondDigest)
        )
    }

    @Test("a nested index counts as absent unless every manifest inside it is complete")
    func nestedIndexRequiresFullContent() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let brokenLeaf = try layout.writeManifestMissingLayer(platform: Platform(arch: "arm64", os: "linux"))
        let incompleteNested = try layout.writeIndexBlob(manifests: [brokenLeaf], annotations: nil)
        let intactLeaf = try layout.writePresentManifest(platform: Platform(arch: "arm64", os: "linux"))
        let completeNested = try layout.writeIndexBlob(manifests: [intactLeaf], annotations: nil)
        let outerIndex = try layout.writeIndexBlob(manifests: [incompleteNested, completeNested], annotations: nil)
        try layout.writeTopIndex(manifests: [outerIndex])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let top = try layout.readTopIndex()
        let rewrittenOuter = try layout.readIndexBlob(digest: top.manifests[0].digest)
        #expect(rewrittenOuter.manifests.map(\.digest) == [completeNested.digest])
    }

    @Test("a corrupt index blob drops that image entry, sibling images still load")
    func corruptIndexBlobIsDropped() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let corruptDigest = try layout.writeBlob(Data("not json {".utf8))
        let corruptEntry = Descriptor(mediaType: MediaTypes.index, digest: corruptDigest, size: 11)
        let intactManifest = try layout.writePresentManifest(platform: Platform(arch: "arm64", os: "linux"))
        let intactEntry = try layout.writeIndexBlob(manifests: [intactManifest], annotations: nil)
        try layout.writeTopIndex(manifests: [corruptEntry, intactEntry])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let top = try layout.readTopIndex()
        #expect(top.manifests.map(\.digest) == [intactEntry.digest])
    }

    @Test("a path-traversal digest is treated as absent, never spliced into a filesystem path")
    func malformedDigestIsAbsent() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let traversal = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: "sha256:../../../../etc/hosts",
            size: 100
        )
        let intact = try layout.writePresentManifest(platform: Platform(arch: "arm64", os: "linux"))
        let indexDescriptor = try layout.writeIndexBlob(manifests: [traversal, intact], annotations: nil)
        try layout.writeTopIndex(manifests: [indexDescriptor])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let top = try layout.readTopIndex()
        let rewrittenIndex = try layout.readIndexBlob(digest: top.manifests[0].digest)
        #expect(rewrittenIndex.manifests.map(\.digest) == [intact.digest])
    }

    @Test("a manifest-typed descriptor whose blob is really an index is dropped")
    func typeConfusedDescriptorIsDropped() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let indexData = try JSONEncoder().encode(Index(manifests: []))
        let digest = "sha256:" + String(repeating: "d", count: 64)
        try layout.writeBlob(indexData, pretendingDigest: digest)
        let confused = Descriptor(mediaType: MediaTypes.imageManifest, digest: digest, size: Int64(indexData.count))

        let intact = try layout.writePresentManifest(platform: Platform(arch: "arm64", os: "linux"))
        let indexDescriptor = try layout.writeIndexBlob(manifests: [confused, intact], annotations: nil)
        try layout.writeTopIndex(manifests: [indexDescriptor])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let top = try layout.readTopIndex()
        let rewrittenIndex = try layout.readIndexBlob(digest: top.manifests[0].digest)
        #expect(rewrittenIndex.manifests.map(\.digest) == [intact.digest])
    }

    @Test("a self-referential index blob is dropped instead of recursing forever")
    func selfReferentialIndexIsDropped() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let cycleDigest = "sha256:" + String(repeating: "c", count: 64)
        let cycle = Descriptor(mediaType: MediaTypes.index, digest: cycleDigest, size: 200)
        try layout.writeBlob(JSONEncoder().encode(Index(manifests: [cycle])), pretendingDigest: cycleDigest)

        let intact = try layout.writePresentManifest(platform: Platform(arch: "arm64", os: "linux"))
        let indexDescriptor = try layout.writeIndexBlob(manifests: [cycle, intact], annotations: nil)
        try layout.writeTopIndex(manifests: [indexDescriptor])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let top = try layout.readTopIndex()
        let rewrittenIndex = try layout.readIndexBlob(digest: top.manifests[0].digest)
        #expect(rewrittenIndex.manifests.map(\.digest) == [intact.digest])
    }

    @Test("two indexes referencing each other are dropped instead of recursing forever")
    func mutuallyRecursiveIndexesAreDropped() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let firstDigest = "sha256:" + String(repeating: "1", count: 64)
        let secondDigest = "sha256:" + String(repeating: "2", count: 64)
        let first = Descriptor(mediaType: MediaTypes.index, digest: firstDigest, size: 200)
        let second = Descriptor(mediaType: MediaTypes.index, digest: secondDigest, size: 200)
        try layout.writeBlob(JSONEncoder().encode(Index(manifests: [second])), pretendingDigest: firstDigest)
        try layout.writeBlob(JSONEncoder().encode(Index(manifests: [first])), pretendingDigest: secondDigest)

        let intact = try layout.writePresentManifest(platform: Platform(arch: "arm64", os: "linux"))
        let indexDescriptor = try layout.writeIndexBlob(manifests: [first, intact], annotations: nil)
        try layout.writeTopIndex(manifests: [indexDescriptor])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let top = try layout.readTopIndex()
        let rewrittenIndex = try layout.readIndexBlob(digest: top.manifests[0].digest)
        #expect(rewrittenIndex.manifests.map(\.digest) == [intact.digest])
    }

    @Test("a chain of indexes that each reference the level below twice prunes without blowing up")
    func doublyReferencedDeepChainDoesNotBlowUp() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        var level = try layout.writePresentManifest(platform: Platform(arch: "arm64", os: "linux"))
        for _ in 0..<30 {
            level = try layout.writeIndexBlob(manifests: [level, level], annotations: nil)
        }
        try layout.writeTopIndex(manifests: [level])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let top = try layout.readTopIndex()
        #expect(top.manifests.count == 1)
    }

    @Test("a chain of distinct nested indexes deeper than the cap is rejected, not recursed unbounded")
    func deepDistinctChainIsBounded() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        var level = try layout.writePresentManifest(platform: Platform(arch: "arm64", os: "linux"))
        for _ in 0..<200 {
            level = try layout.writeIndexBlob(manifests: [level], annotations: nil)
        }
        try layout.writeTopIndex(manifests: [level])

        #expect(throws: OCILayoutPruner.PruneError.indexNestingTooDeep) {
            try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))
        }
    }

    @Test("one complete index referenced by two parents stays present under both")
    func sharedSubIndexIsPresentUnderEveryParent() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let shared = try layout.writeIndexBlob(
            manifests: [try layout.writePresentManifest(platform: Platform(arch: "arm64", os: "linux"))],
            annotations: nil)
        let left = try layout.writeIndexBlob(manifests: [shared], annotations: ["ref": "left"])
        let right = try layout.writeIndexBlob(manifests: [shared], annotations: ["ref": "right"])
        try layout.writeTopIndex(manifests: [left, right])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let top = try layout.readTopIndex()
        #expect(top.manifests.map { $0.annotations?["ref"] } == ["left", "right"])
    }

    @Test("a rewritten shared index retains every top-level tag annotation")
    func sharedRewrittenIndexRetainsCallerMetadata() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let present = try layout.writePresentManifest(
            platform: Platform(arch: "arm64", os: "linux")
        )
        let missing = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: "sha256:" + String(repeating: "f", count: 64),
            size: 500,
            platform: Platform(arch: "amd64", os: "linux")
        )
        let shared = try layout.writeIndexBlob(
            manifests: [present, missing],
            annotations: nil
        )
        let first = Descriptor(
            mediaType: shared.mediaType,
            digest: shared.digest,
            size: shared.size,
            annotations: ["io.containerd.image.name": "first:latest"]
        )
        let second = Descriptor(
            mediaType: shared.mediaType,
            digest: shared.digest,
            size: shared.size,
            annotations: ["io.containerd.image.name": "second:latest"]
        )
        try layout.writeTopIndex(manifests: [first, second])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(
            at: layout.root,
            logger: Logger(label: "test")
        )

        let top = try layout.readTopIndex()
        #expect(top.manifests.map(\.digest).count == 2)
        #expect(top.manifests[0].digest == top.manifests[1].digest)
        #expect(
            top.manifests.compactMap {
                $0.annotations?["io.containerd.image.name"]
            } == ["first:latest", "second:latest"]
        )
    }

    @Test("artifact ordering rewrites metadata-distinct descriptors sharing a digest")
    func sharedDigestArtifactOrderingIsPersisted() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let runnable = try layout.writePresentManifest(
            platform: Platform(arch: "arm64", os: "linux")
        )
        let artifact = Descriptor(
            mediaType: runnable.mediaType,
            digest: runnable.digest,
            size: runnable.size,
            annotations: [
                "vnd.docker.reference.type": "attestation-manifest",
                "vnd.docker.reference.digest": runnable.digest,
            ],
            platform: runnable.platform
        )
        try layout.writeTopIndex(manifests: [artifact, runnable])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(
            at: layout.root,
            logger: Logger(label: "test")
        )

        let top = try layout.readTopIndex()
        #expect(top.manifests.map(\.digest) == [runnable.digest, runnable.digest])
        #expect(
            top.manifests.map {
                $0.annotations?["vnd.docker.reference.type"]
            } == [nil, "attestation-manifest"]
        )
    }

    @Test("presence cache never aliases platform semantics for one shared digest")
    func sharedDigestPlatformSelectionDoesNotCrossPoisonCache() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let present = try layout.writePresentManifest(
            platform: Platform(arch: "arm64", os: "linux")
        )
        let nonSelected = Descriptor(
            mediaType: present.mediaType,
            digest: present.digest,
            size: present.size,
            platform: Platform(arch: "amd64", os: "linux")
        )
        let selected = Descriptor(
            mediaType: present.mediaType,
            digest: present.digest,
            size: present.size,
            platform: Platform(arch: "arm64", os: "linux")
        )
        try layout.writeTopIndex(manifests: [nonSelected, selected])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(
            at: layout.root,
            platform: Platform(arch: "arm64", os: "linux"),
            logger: Logger(label: "test")
        )

        let top = try layout.readTopIndex()
        #expect(top.manifests == [selected])
    }

    @Test("coherent graph cache keeps descriptor platform semantics in either order")
    func coherentGraphSharedDigestPlatformOrderIsStable() throws {
        for validFirst in [false, true] {
            let layout = try LayoutFixture()
            defer { layout.cleanUp() }

            let manifest = try layout.writePresentManifest(
                platform: Platform(arch: "arm64", os: "linux")
            )
            let runnable = Descriptor(
                mediaType: manifest.mediaType,
                digest: manifest.digest,
                size: manifest.size,
                platform: Platform(arch: "arm64", os: "linux")
            )
            let missingPlatform = Descriptor(
                mediaType: manifest.mediaType,
                digest: manifest.digest,
                size: manifest.size
            )
            let children =
                validFirst
                ? [runnable, missingPlatform]
                : [missingPlatform, runnable]
            let root = try layout.writeIndexBlob(
                manifests: children,
                annotations: nil
            )

            #expect(
                try OCILayoutPruner.containsCoherentRunnableImage(
                    for: root,
                    in: layout.root
                )
            )
        }
    }

    @Test("coherent graph traversal bounds repeated shared artifact subgraphs")
    func coherentGraphRepeatedSharedArtifactDAGIsBounded() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let runnable = try layout.writePresentManifest(
            platform: Platform(arch: "arm64", os: "linux")
        )
        let artifact = Descriptor(
            mediaType: runnable.mediaType,
            digest: runnable.digest,
            size: runnable.size,
            annotations: [
                "vnd.docker.reference.type": "attestation-manifest",
                "vnd.docker.reference.digest": runnable.digest,
            ],
            platform: runnable.platform
        )
        var shared = try layout.writeIndexBlob(
            manifests: [runnable, artifact],
            annotations: nil
        )
        for _ in 0..<30 {
            shared = try layout.writeIndexBlob(
                manifests: [shared, shared],
                annotations: nil
            )
        }

        #expect(
            try OCILayoutPruner.containsCoherentRunnableImage(
                for: shared,
                in: layout.root
            )
        )
    }

    @Test("a present index sharing an index with a cyclic sibling is kept, the cycle is pruned away")
    func presentIndexAlongsideCyclicReferenceSurvives() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let present = try layout.writeIndexBlob(
            manifests: [try layout.writePresentManifest(platform: Platform(arch: "arm64", os: "linux"))],
            annotations: nil)

        let cyclicDigest = "sha256:" + String(repeating: "e", count: 64)
        let cyclic = Descriptor(mediaType: MediaTypes.index, digest: cyclicDigest, size: 200)
        try layout.writeBlob(JSONEncoder().encode(Index(manifests: [present, cyclic])), pretendingDigest: cyclicDigest)

        try layout.writeTopIndex(manifests: [cyclic])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let top = try layout.readTopIndex()
        let rewritten = try layout.readIndexBlob(digest: top.manifests[0].digest)
        #expect(rewritten.manifests.map(\.digest) == [present.digest])
    }

    @Test("a digest-named directory at a layer path counts as absent, not a present blob")
    func directoryAtBlobPathIsAbsent() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let configDigest = try layout.writeBlob(Data(#"{"architecture":"arm64","os":"linux"}"#.utf8))
        let layerDigest = "sha256:" + String(repeating: "e", count: 64)
        try FileManager.default.createDirectory(
            at: layout.root.appendingPathComponent("blobs/sha256/\(layerDigest.dropFirst("sha256:".count))"), withIntermediateDirectories: true)
        let brokenManifest = Manifest(
            config: Descriptor(mediaType: MediaTypes.imageConfig, digest: configDigest, size: 10),
            layers: [Descriptor(mediaType: MediaTypes.imageLayerGzip, digest: layerDigest, size: 10)])
        let brokenData = try JSONEncoder().encode(brokenManifest)
        let broken = Descriptor(
            mediaType: MediaTypes.imageManifest, digest: try layout.writeBlob(brokenData), size: Int64(brokenData.count), platform: Platform(arch: "arm64", os: "linux"))

        let intact = try layout.writePresentManifest(platform: Platform(arch: "riscv64", os: "linux"))
        let indexDescriptor = try layout.writeIndexBlob(manifests: [broken, intact], annotations: nil)
        try layout.writeTopIndex(manifests: [indexDescriptor])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let rewritten = try layout.readIndexBlob(digest: try layout.readTopIndex().manifests[0].digest)
        #expect(rewritten.manifests.map(\.digest) == [intact.digest])
    }

    @Test("a manifest-typed descriptor sharing a digest with a present index is not falsely kept")
    func mediaTypeDoesNotAliasInPresenceCache() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let sharedIndex = try layout.writeIndexBlob(
            manifests: [try layout.writePresentManifest(platform: Platform(arch: "arm64", os: "linux"))], annotations: nil)
        let confusedManifest = Descriptor(
            mediaType: MediaTypes.imageManifest, digest: sharedIndex.digest, size: sharedIndex.size, platform: Platform(arch: "amd64", os: "linux"))
        let outer = try layout.writeIndexBlob(manifests: [sharedIndex, confusedManifest], annotations: nil)
        try layout.writeTopIndex(manifests: [outer])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let rewritten = try layout.readIndexBlob(digest: try layout.readTopIndex().manifests[0].digest)
        #expect(rewritten.manifests.map(\.mediaType) == [MediaTypes.index])
    }

    @Test("exact identity selection distinguishes same-platform sibling manifests and configs")
    func exactIdentitySelectsSamePlatformSibling() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let arm64 = Platform(arch: "arm64", os: "linux")
        let first = try layout.writePresentManifest(
            platform: arm64,
            identity: "first"
        )
        let second = try layout.writePresentManifest(
            platform: arm64,
            identity: "second"
        )
        let root = try layout.writeIndexBlob(
            manifests: [first, second],
            annotations: nil
        )
        try layout.writeTopIndex(manifests: [root])
        let secondConfigDigest = try layout.readManifest(
            digest: second.digest
        ).config.digest

        try OCILayoutPruner.selectExactIdentities(
            at: layout.root,
            constraints: [
                .exactManifest(
                    manifestDigest: second.digest,
                    configDigest: secondConfigDigest
                )
            ],
            platform: nil,
            logger: Logger(label: "test")
        )

        let selected = try #require(layout.readTopIndex().manifests.first)
        #expect(selected.digest == second.digest)
        #expect(selected.digest != first.digest)
        #expect(selected.platform == arm64)
        #expect(
            try layout.readManifest(digest: selected.digest).config.digest
                == secondConfigDigest
        )
    }

    @Test("nested-index identity selection stops at the requested index boundary")
    func exactNestedIndexBoundaryIsPreserved() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let targetManifest = try layout.writePresentManifest(
            platform: Platform(arch: "arm64", os: "linux"),
            identity: "target"
        )
        let targetIndex = try layout.writeIndexBlob(
            manifests: [targetManifest],
            annotations: ["scope": "target"]
        )
        let siblingManifest = try layout.writePresentManifest(
            platform: Platform(arch: "amd64", os: "linux"),
            identity: "sibling"
        )
        let siblingIndex = try layout.writeIndexBlob(
            manifests: [siblingManifest],
            annotations: ["scope": "sibling"]
        )
        let outer = try layout.writeIndexBlob(
            manifests: [siblingIndex, targetIndex],
            annotations: nil
        )
        try layout.writeTopIndex(manifests: [outer])

        try OCILayoutPruner.selectExactIdentities(
            at: layout.root,
            constraints: [.descendantOfIndex(targetIndex.digest)],
            platform: nil,
            logger: Logger(label: "test")
        )

        let selected = try #require(layout.readTopIndex().manifests.first)
        #expect(selected.digest == targetIndex.digest)
        #expect(selected.mediaType == MediaTypes.index)
        #expect(selected.digest != targetManifest.digest)
        #expect(try layout.readIndexBlob(digest: selected.digest).manifests == [targetManifest])
    }

    @Test("nested-index identity search cannot cross its paired top-level root")
    func exactNestedIndexSearchIsScopedToRoot() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let firstRoot = try layout.writeIndexBlob(
            manifests: [
                try layout.writePresentManifest(
                    platform: Platform(arch: "arm64", os: "linux"),
                    identity: "first-root"
                )
            ],
            annotations: nil
        )
        let targetIndex = try layout.writeIndexBlob(
            manifests: [
                try layout.writePresentManifest(
                    platform: Platform(arch: "amd64", os: "linux"),
                    identity: "second-root"
                )
            ],
            annotations: nil
        )
        try layout.writeTopIndex(manifests: [firstRoot, targetIndex])

        #expect(throws: OCILayoutPruner.PruneError.nothingLoadable) {
            try OCILayoutPruner.selectExactIdentities(
                at: layout.root,
                constraints: [
                    .descendantOfIndex(targetIndex.digest),
                    .unconstrained,
                ],
                platform: nil,
                logger: Logger(label: "test")
            )
        }
    }

    @Test("exact manifest identity enforces an explicitly requested platform")
    func exactManifestRequiresExplicitPlatformMatch() throws {
        let arm64 = Platform(arch: "arm64", os: "linux")

        let matching = try LayoutFixture()
        defer { matching.cleanUp() }
        let matchingManifest = try matching.writePresentManifest(
            platform: arm64,
            identity: "matching"
        )
        try matching.writeTopIndex(manifests: [matchingManifest])
        let matchingConfig = try matching.readManifest(
            digest: matchingManifest.digest
        ).config.digest
        try OCILayoutPruner.selectExactIdentities(
            at: matching.root,
            constraints: [
                .exactManifest(
                    manifestDigest: matchingManifest.digest,
                    configDigest: matchingConfig
                )
            ],
            platform: arm64,
            logger: Logger(label: "test")
        )
        #expect(
            try matching.readTopIndex().manifests.first?.digest
                == matchingManifest.digest
        )

        let mismatching = try LayoutFixture()
        defer { mismatching.cleanUp() }
        let mismatchingManifest = try mismatching.writePresentManifest(
            platform: arm64,
            identity: "mismatching"
        )
        try mismatching.writeTopIndex(manifests: [mismatchingManifest])
        let mismatchingConfig = try mismatching.readManifest(
            digest: mismatchingManifest.digest
        ).config.digest
        #expect(throws: OCILayoutPruner.PruneError.nothingLoadable) {
            try OCILayoutPruner.selectExactIdentities(
                at: mismatching.root,
                constraints: [
                    .exactManifest(
                        manifestDigest: mismatchingManifest.digest,
                        configDigest: mismatchingConfig
                    )
                ],
                platform: Platform(arch: "amd64", os: "linux"),
                logger: Logger(label: "test")
            )
        }
    }

    @Test("exact identity selection preserves top-level reference annotations")
    func exactIdentityPreservesTopReferenceAnnotations() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let manifest = try layout.writePresentManifest(
            platform: Platform(arch: "arm64", os: "linux"),
            identity: "annotated"
        )
        let child = Descriptor(
            mediaType: manifest.mediaType,
            digest: manifest.digest,
            size: manifest.size,
            annotations: [
                "child-only": "preserved",
                "org.opencontainers.image.ref.name": "child:old",
            ],
            platform: manifest.platform
        )
        let root = try layout.writeIndexBlob(
            manifests: [child],
            annotations: [
                "io.containerd.image.name": "docker.io/example/app:latest",
                "org.opencontainers.image.ref.name": "app:latest",
            ]
        )
        try layout.writeTopIndex(manifests: [root])
        let configDigest = try layout.readManifest(
            digest: manifest.digest
        ).config.digest

        try OCILayoutPruner.selectExactIdentities(
            at: layout.root,
            constraints: [
                .exactManifest(
                    manifestDigest: manifest.digest,
                    configDigest: configDigest
                )
            ],
            platform: nil,
            logger: Logger(label: "test")
        )

        let selected = try #require(layout.readTopIndex().manifests.first)
        #expect(
            selected.annotations?["io.containerd.image.name"]
                == "docker.io/example/app:latest"
        )
        #expect(
            selected.annotations?["org.opencontainers.image.ref.name"]
                == "app:latest"
        )
        #expect(selected.annotations?["child-only"] == "preserved")
    }

    @Test("a layout with nothing loadable throws instead of importing an empty index")
    func nothingLoadableThrows() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let absent = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: "sha256:" + String(repeating: "b", count: 64),
            size: 500
        )
        let indexDescriptor = try layout.writeIndexBlob(manifests: [absent], annotations: nil)
        try layout.writeTopIndex(manifests: [indexDescriptor])

        #expect(throws: OCILayoutPruner.PruneError.nothingLoadable) {
            try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))
        }
    }

    @Test("a top-level descriptor pointing directly at a present manifest passes through")
    func directManifestReferencePassesThrough() throws {
        let layout = try LayoutFixture()
        defer { layout.cleanUp() }

        let manifest = try layout.writePresentManifest(platform: Platform(arch: "arm64", os: "linux"))
        try layout.writeTopIndex(manifests: [manifest])

        try OCILayoutPruner.pruneManifestsWithMissingBlobs(at: layout.root, logger: Logger(label: "test"))

        let top = try layout.readTopIndex()
        #expect(top.manifests.map(\.digest) == [manifest.digest])
    }
}

private struct LayoutFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("oci-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("blobs/sha256"), withIntermediateDirectories: true)
        try Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8).write(to: root.appendingPathComponent("oci-layout"))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeBlob(_ data: Data) throws -> String {
        let digest = "sha256:" + data.sha256Hex()
        try writeBlob(data, pretendingDigest: digest)
        return digest
    }

    func writeBlob(_ data: Data, pretendingDigest digest: String) throws {
        try data.write(to: root.appendingPathComponent("blobs/sha256/\(digest.dropFirst("sha256:".count))"))
    }

    func writePresentManifest(
        platform: Platform,
        identity: String = ""
    ) throws -> Descriptor {
        let configDigest = try writeBlob(
            Data(
                #"{"architecture":"\#(platform.architecture)","os":"linux","identity":"\#(identity)"}"#.utf8
            )
        )
        let layerDigest = try writeBlob(
            Data(
                "layer-content-\(platform.architecture)-\(identity)".utf8
            )
        )
        let manifest = Manifest(
            config: Descriptor(mediaType: MediaTypes.imageConfig, digest: configDigest, size: 10),
            layers: [Descriptor(mediaType: MediaTypes.imageLayerGzip, digest: layerDigest, size: 10)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let digest = try writeBlob(data)
        return Descriptor(mediaType: MediaTypes.imageManifest, digest: digest, size: Int64(data.count), platform: platform)
    }

    func writeManifestMissingLayer(platform: Platform) throws -> Descriptor {
        let configDigest = try writeBlob(Data(#"{"architecture":"\#(platform.architecture)","os":"linux"}"#.utf8))
        let manifest = Manifest(
            config: Descriptor(mediaType: MediaTypes.imageConfig, digest: configDigest, size: 10),
            layers: [Descriptor(mediaType: MediaTypes.imageLayerGzip, digest: "sha256:" + String(repeating: "c", count: 64), size: 10)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let digest = try writeBlob(data)
        return Descriptor(mediaType: MediaTypes.imageManifest, digest: digest, size: Int64(data.count), platform: platform)
    }

    func writeIndexBlob(
        manifests: [Descriptor],
        annotations: [String: String]?,
        indexAnnotations: [String: String]? = nil
    ) throws -> Descriptor {
        let index = Index(
            manifests: manifests,
            annotations: indexAnnotations
        )
        let data = try JSONEncoder().encode(index)
        let digest = try writeBlob(data)
        return Descriptor(mediaType: MediaTypes.index, digest: digest, size: Int64(data.count), annotations: annotations)
    }

    func writeTopIndex(manifests: [Descriptor]) throws {
        let index = Index(manifests: manifests)
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent("index.json"))
    }

    func readTopIndex() throws -> Index {
        try JSONDecoder().decode(Index.self, from: Data(contentsOf: root.appendingPathComponent("index.json")))
    }

    func readIndexBlob(digest: String) throws -> Index {
        try JSONDecoder().decode(Index.self, from: blobData(digest: digest))
    }

    func readManifest(digest: String) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: blobData(digest: digest))
    }

    func blobData(digest: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent("blobs/sha256/\(digest.dropFirst("sha256:".count))"))
    }
}
