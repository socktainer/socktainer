import Foundation
import Testing

@testable import GlassDock

@Suite("Image reference constraint store")
struct ImageReferenceConstraintStoreTests {
    private static let reference = "docker.io/library/example:latest"

    @Test("the Apple tag owner selects the safe side of a pending journal")
    func pendingJournalUsesCurrentRootAsCommitWitness() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImageReferenceConstraintStore(appSupportURL: directory)
        let oldRoot = Self.digest("a")
        let newRoot = Self.digest("b")
        let oldConstraint = RunnableImageIdentityConstraint.exactManifest(
            manifestDigest: Self.digest("c"),
            configDigest: Self.digest("f")
        )
        let newConstraint = RunnableImageIdentityConstraint.exactManifest(
            manifestDigest: Self.digest("d"),
            configDigest: Self.digest("0")
        )

        let initial = try await store.prepare([
            ImageReferenceConstraintAssignment(
                reference: Self.reference,
                rootDigest: oldRoot,
                constraint: oldConstraint
            )
        ])
        try await store.commit(initial)
        _ = try await store.prepare([
            ImageReferenceConstraintAssignment(
                reference: Self.reference,
                rootDigest: newRoot,
                constraint: newConstraint
            )
        ])

        #expect(
            try await store.effectiveEntries(
                currentRootByReference: [Self.reference: oldRoot]
            )[Self.reference]
                == .init(rootDigest: oldRoot, constraint: oldConstraint)
        )
        #expect(
            try await store.effectiveEntries(
                currentRootByReference: [Self.reference: newRoot]
            )[Self.reference]
                == .init(rootDigest: newRoot, constraint: newConstraint)
        )
        #expect(
            try await store.effectiveEntries(
                currentRootByReference: [Self.reference: Self.digest("e")]
            )[Self.reference] == nil
        )
    }

    @Test("reconciliation compacts the witnessed side and rejects stale roots")
    func reconciliationCompactsAndValidatesRoot() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImageReferenceConstraintStore(appSupportURL: directory)
        let root = Self.digest("1")
        let constraint = RunnableImageIdentityConstraint.descendantOfIndex(
            Self.digest("2")
        )
        _ = try await store.prepare([
            ImageReferenceConstraintAssignment(
                reference: Self.reference,
                rootDigest: root,
                constraint: constraint
            )
        ])

        try await store.reconcile(
            currentRootByReference: [Self.reference: root]
        )
        #expect(
            try await store.effectiveEntries(
                currentRootByReference: [Self.reference: root]
            )[Self.reference]
                == .init(rootDigest: root, constraint: constraint)
        )
        #expect(
            try await store.effectiveEntries(
                currentRootByReference: [Self.reference: Self.digest("3")]
            )[Self.reference] == nil
        )
    }

    @Test("an unconstrained replacement removes an old exact selector")
    func unconstrainedReplacementClearsSelector() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImageReferenceConstraintStore(appSupportURL: directory)
        let root = Self.digest("4")
        let first = try await store.prepare([
            ImageReferenceConstraintAssignment(
                reference: Self.reference,
                rootDigest: root,
                constraint: .exactManifest(
                    manifestDigest: Self.digest("5"),
                    configDigest: Self.digest("6")
                )
            )
        ])
        try await store.commit(first)
        let replacement = try await store.prepare([
            ImageReferenceConstraintAssignment(
                reference: Self.reference,
                rootDigest: root,
                constraint: .unconstrained
            )
        ])
        try await store.commit(replacement)

        #expect(
            try await store.effectiveEntries(
                currentRootByReference: [Self.reference: root]
            ).isEmpty
        )
    }

    @Test("a pending same-root unconstrained replacement cannot resurrect the old selector")
    func pendingSameRootUnconstrainedClearsSelector() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImageReferenceConstraintStore(appSupportURL: directory)
        let root = Self.digest("c")
        let initial = try await store.prepare([
            .init(
                reference: Self.reference,
                rootDigest: root,
                constraint: .exactManifest(
                    manifestDigest: Self.digest("d"),
                    configDigest: Self.digest("e")
                )
            )
        ])
        try await store.commit(initial)
        _ = try await store.prepare([
            .init(
                reference: Self.reference,
                rootDigest: root,
                constraint: .unconstrained
            )
        ])

        #expect(
            try await store.effectiveEntries(
                currentRootByReference: [Self.reference: root]
            ).isEmpty
        )
    }

    @Test("a same-root selector change commits atomically at journal publication")
    func sameRootSelectorUsesNewJournalSide() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImageReferenceConstraintStore(appSupportURL: directory)
        let root = Self.digest("7")
        let old = RunnableImageIdentityConstraint.exactManifest(
            manifestDigest: Self.digest("8"),
            configDigest: Self.digest("9")
        )
        let new = RunnableImageIdentityConstraint.exactManifest(
            manifestDigest: Self.digest("a"),
            configDigest: Self.digest("b")
        )
        let initial = try await store.prepare([
            .init(reference: Self.reference, rootDigest: root, constraint: old)
        ])
        try await store.commit(initial)
        _ = try await store.prepare([
            .init(reference: Self.reference, rootDigest: root, constraint: new)
        ])

        #expect(
            try await store.effectiveEntries(
                currentRootByReference: [Self.reference: root]
            )[Self.reference]
                == .init(rootDigest: root, constraint: new)
        )
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "image-reference-constraints-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private static func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }
}
