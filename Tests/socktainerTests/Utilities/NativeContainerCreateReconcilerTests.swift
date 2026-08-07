import ContainerAPIClient
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import Dispatch
import Foundation
import Logging
import Testing

@testable import socktainer

@Suite("Native container create reconciliation")
struct NativeContainerCreateReconcilerTests {
    @Test("exact snapshot preparation excludes a concurrent prune mutation")
    func snapshotPreparationExcludesPrune() async throws {
        let coordinator = ImageMutationCoordinator()
        let gate = AsyncTestGate()
        let mutationProbe = BooleanProbe()
        let protected = Task {
            try await ContainerCreateRoute.withImageContentProtected(
                by: coordinator
            ) {
                await gate.enterAndWait()
                return true
            }
        }
        await gate.waitUntilEntered()

        let prune = Task {
            try await coordinator.performMutation {
                await mutationProbe.setTrue()
            }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!(await mutationProbe.value))

        await gate.open()
        #expect(try await protected.value)
        try await prune.value
        #expect(await mutationProbe.value)
    }

    @Test("commit followed by an interrupted reply is recognized as committed")
    func commitThenThrow() async {
        let fixture = ImageLeaseFixture()
        let configuration = makeConfiguration(
            id: "commit-then-throw",
            image: fixture.lease.image.description
        )
        let native = FakeNativeContainerCreator(
            behavior: .throwAfterCommit(.interrupted)
        )
        let leaseManager = RecordingLeaseManager()
        let committer = NativeContainerCreateCommitter(
            client: native,
            mutationCoordinator: ImageMutationCoordinator(),
            leaseManager: leaseManager,
            reconciliationAttempts: 1,
            reconciliationDelay: .zero
        )

        let result = await committer.commit(
            configuration: configuration,
            options: .default,
            kernel: testKernel(),
            lease: fixture.lease
        )

        guard case .committed(let snapshot) = result else {
            Issue.record("expected commit-then-throw to reconcile as committed")
            return
        }
        #expect(snapshot.id == configuration.id)
        #expect(
            NativeContainerCreateCommitter.configurationsExactlyMatch(
                snapshot.configuration,
                configuration
            )
        )
        #expect(await leaseManager.verifyCount == 1)
    }

    @Test("a conflicting configuration is never treated as this create")
    func conflictingConfiguration() async {
        let fixture = ImageLeaseFixture()
        let configuration = makeConfiguration(
            id: "conflicting-create",
            image: fixture.lease.image.description
        )
        let other = ImageDescription(
            reference: "socktainer-runtime@sha256:\(String(repeating: "9", count: 64))",
            descriptor: Descriptor(
                mediaType: MediaTypes.index,
                digest: "sha256:\(String(repeating: "9", count: 64))",
                size: 2
            )
        )
        let native = FakeNativeContainerCreator(
            behavior: .throwWithConflictingCommit(other)
        )
        let committer = NativeContainerCreateCommitter(
            client: native,
            mutationCoordinator: ImageMutationCoordinator(),
            leaseManager: RecordingLeaseManager(),
            reconciliationAttempts: 1,
            reconciliationDelay: .zero
        )

        let result = await committer.commit(
            configuration: configuration,
            options: .default,
            kernel: testKernel(),
            lease: fixture.lease
        )

        guard case .conflicting(let snapshot, _) = result else {
            Issue.record("expected exact-configuration mismatch to conflict")
            return
        }
        #expect(snapshot.configuration.image.reference == other.reference)
    }

    @Test("interrupted absent create remains indeterminate")
    func interruptedAbsentIsIndeterminate() async {
        let fixture = ImageLeaseFixture()
        let committer = NativeContainerCreateCommitter(
            client: FakeNativeContainerCreator(
                behavior: .fail(.interrupted)
            ),
            mutationCoordinator: ImageMutationCoordinator(),
            leaseManager: RecordingLeaseManager(),
            reconciliationAttempts: 1,
            reconciliationDelay: .zero
        )
        let result = await committer.commit(
            configuration: makeConfiguration(
                id: "interrupted-absent",
                image: fixture.lease.image.description
            ),
            options: .default,
            kernel: testKernel(),
            lease: fixture.lease
        )
        guard case .indeterminate = result else {
            Issue.record("transport interruption must preserve rootfs and reservation")
            return
        }
    }

    @Test("server-side invalid argument plus confirmed absence is definitive")
    func invalidAbsentIsDefinitive() async {
        let fixture = ImageLeaseFixture()
        let committer = NativeContainerCreateCommitter(
            client: FakeNativeContainerCreator(
                behavior: .fail(.invalidArgument)
            ),
            mutationCoordinator: ImageMutationCoordinator(),
            leaseManager: RecordingLeaseManager(),
            reconciliationAttempts: 1,
            reconciliationDelay: .zero
        )
        let result = await committer.commit(
            configuration: makeConfiguration(
                id: "invalid-absent",
                image: fixture.lease.image.description
            ),
            options: .default,
            kernel: testKernel(),
            lease: fixture.lease
        )
        guard case .definitivelyFailed = result else {
            Issue.record("server validation failure should permit owned rollback")
            return
        }
    }

    @Test("wrapped transport errors are classified recursively")
    func wrappedInterruptionIsAmbiguous() {
        let error = ContainerizationError(
            .internalError,
            message: "create failed",
            cause: ContainerizationError(
                .interrupted,
                message: "connection interrupted"
            )
        )
        #expect(
            NativeContainerCreateCommitter.isAmbiguousTransportFailure(error)
        )
    }
}

@Suite("Container create lease convergence")
struct ContainerCreateLeaseConvergenceTests {
    @Test("pre-materialization failure and defer converge exactly once")
    func preMaterializationConvergesOnce() async {
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let reservation = await registry.reserve(fixture.lease)
        let reconciler = RecordingLeaseReconciler()
        let convergence = ContainerCreateLeaseConvergence(
            rootDescriptor: fixture.lease.image.descriptor,
            reservation: reservation,
            reconciler: reconciler
        )

        await convergence.converge()
        await convergence.converge()

        #expect(await reconciler.callCount == 1)
        #expect(await reconciler.lastReservationID == reservation.reservationID)
    }

    @Test("post-materialization failure and concurrent defer converge exactly once")
    func postMaterializationConvergesOnce() async {
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let reservation = await registry.reserve(fixture.lease)
        let reconciler = RecordingLeaseReconciler()
        let convergence = ContainerCreateLeaseConvergence(
            rootDescriptor: fixture.lease.image.descriptor,
            reservation: reservation,
            reconciler: reconciler
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { await convergence.converge() }
            }
        }

        #expect(await reconciler.callCount == 1)
    }

    @Test("ambiguous create handoff prevents handler defer from releasing")
    func handoffPreventsEarlyRelease() async {
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let reservation = await registry.reserve(fixture.lease)
        let reconciler = RecordingLeaseReconciler()
        let convergence = ContainerCreateLeaseConvergence(
            rootDescriptor: fixture.lease.image.descriptor,
            reservation: reservation,
            reconciler: reconciler
        )

        await convergence.handOff()
        await convergence.converge()

        #expect(await reconciler.callCount == 0)
    }
}

@Suite("Exact rootfs materialization ownership")
struct ContainerRootFSMaterializerTests {
    @Test("final bundle appears only after marker and rootfs are complete")
    func bundlePublicationIsAtomic() async throws {
        let root = try makeTemporaryAppRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let reservation = await registry.reserve(fixture.lease)
        let gate = MaterializationPublicationGate()
        let materializer = ContainerRootFSMaterializer(
            appSupportURL: root,
            beforePublish: { staging, final in
                gate.pause(staging: staging, final: final)
            }
        )
        let source = try makeSourceFilesystem(in: root)

        let task = Task.detached {
            try materializer.materialize(
                snapshot: source,
                containerID: "atomic-visibility",
                readOnly: true,
                reservation: reservation
            )
        }
        await gate.waitUntilPaused()

        let paths = gate.paths()
        #expect(paths != nil)
        if let paths {
            #expect(!FileManager.default.fileExists(atPath: paths.final.path))
            #expect(
                PreparedContainerRootFS.ownership(at: paths.staging)?
                    .reservationID == reservation.reservationID
            )
            let visibleOwnership = try materializer.ownedPreCreateBundle(
                containerID: "atomic-visibility"
            )?.ownership
            #expect(visibleOwnership == nil)
            #expect(
                FileManager.default.fileExists(
                    atPath: paths.staging.appendingPathComponent(
                        "rootfs.ext4"
                    ).path
                )
            )
            let permissions =
                try? FileManager.default.attributesOfItem(
                    atPath: paths.staging.path
                )[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o700)
        }

        gate.resume()
        let prepared = try await task.value
        #expect(
            prepared.filesystem.source
                == prepared.bundleDirectory.appendingPathComponent(
                    "rootfs.ext4"
                ).path
        )
        #expect(
            PreparedContainerRootFS.ownership(at: prepared.bundleDirectory)
                == prepared.ownership
        )
        #expect(stagingBundles(in: root).isEmpty)
        prepared.rollback()
    }

    @Test("cancellation in the pre-publish crash window exposes no final bundle")
    func prePublishCancellationCleansPrivateStaging() async throws {
        let root = try makeTemporaryAppRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let reservation = await registry.reserve(fixture.lease)
        let gate = MaterializationPublicationGate()
        let materializer = ContainerRootFSMaterializer(
            appSupportURL: root,
            beforePublish: { staging, final in
                gate.pause(staging: staging, final: final)
            }
        )
        let source = try makeSourceFilesystem(in: root)

        let task = Task.detached {
            try materializer.materialize(
                snapshot: source,
                containerID: "cancel-before-publish",
                readOnly: false,
                reservation: reservation
            )
        }
        await gate.waitUntilPaused()
        let final = root.appendingPathComponent(
            "containers/cancel-before-publish",
            isDirectory: true
        )
        #expect(!FileManager.default.fileExists(atPath: final.path))

        task.cancel()
        gate.resume()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: final.path))
        #expect(stagingBundles(in: root).isEmpty)
    }

    @Test("staging recovery removes only stale inactive current-format ownership")
    func stalePrivateStagingRecoveryIsConservative() async throws {
        let root = try makeTemporaryAppRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let staleReservation = await registry.reserve(fixture.lease)
        let activeReservation = await registry.reserve(fixture.lease)
        let freshReservation = await registry.reserve(fixture.lease)
        let malformedReservation = await registry.reserve(fixture.lease)
        let incompatibleReservation = await registry.reserve(fixture.lease)
        let foreignReservation = await registry.reserve(fixture.lease)
        let nonUUIDReservation = await registry.reserve(fixture.lease)
        let now = Date()
        let stale = now.addingTimeInterval(-3_600)

        let eligible = try makePrivateStagingBundle(
            in: root,
            ownership: .init(
                containerID: "eligible",
                reservation: staleReservation,
                createdAt: stale
            )
        )
        let active = try makePrivateStagingBundle(
            in: root,
            ownership: .init(
                containerID: "active",
                reservation: activeReservation,
                createdAt: stale
            )
        )
        let fresh = try makePrivateStagingBundle(
            in: root,
            ownership: .init(
                containerID: "fresh",
                reservation: freshReservation,
                createdAt: now
            )
        )
        let malformed = try makePrivateStagingBundle(
            in: root,
            markerData: Data("not-json".utf8)
        )
        let incompatibleOwnership = PreparedContainerRootFS.Ownership(
            containerID: "incompatible",
            reservation: incompatibleReservation,
            createdAt: stale
        )
        let incompatible = try makePrivateStagingBundle(
            in: root,
            markerData: try encodedOwnership(
                incompatibleOwnership,
                formatVersion: 999
            )
        )
        let foreign = try makePrivateStagingBundle(
            in: root,
            name: "foreign-staging-\(UUID().uuidString)",
            ownership: .init(
                containerID: "foreign",
                reservation: foreignReservation,
                createdAt: stale
            )
        )
        let nonUUID = try makePrivateStagingBundle(
            in: root,
            name:
                "\(ContainerRootFSMaterializer.stagingBundlePrefix)not-a-uuid",
            ownership: .init(
                containerID: "non-uuid",
                reservation: nonUUIDReservation,
                createdAt: stale
            )
        )
        for reservation in [
            staleReservation,
            freshReservation,
            malformedReservation,
            incompatibleReservation,
            foreignReservation,
            nonUUIDReservation,
        ] {
            await registry.release(reservation)
        }

        let recovered = await ContainerRootFSMaterializer(
            appSupportURL: root
        ).recoverStalePrivateStagingBundles(
            reservationRegistry: registry,
            staleAfter: 60,
            now: now
        )

        #expect(recovered == 1)
        #expect(!FileManager.default.fileExists(atPath: eligible.path))
        for preserved in [active, fresh, malformed, incompatible, foreign, nonUUID] {
            #expect(FileManager.default.fileExists(atPath: preserved.path))
        }
        await registry.release(activeReservation)
    }

    @Test("staging recovery is capped and drains leftovers on later passes")
    func stalePrivateStagingRecoveryIsBounded() async throws {
        let root = try makeTemporaryAppRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let now = Date()
        let count = ContainerRootFSMaterializer.maximumStagingRecoveriesPerPass + 1
        for index in 0..<count {
            let reservation = await registry.reserve(fixture.lease)
            _ = try makePrivateStagingBundle(
                in: root,
                ownership: .init(
                    containerID: "bounded-\(index)",
                    reservation: reservation,
                    createdAt: now.addingTimeInterval(-3_600)
                )
            )
            await registry.release(reservation)
        }
        let materializer = ContainerRootFSMaterializer(appSupportURL: root)

        let first = await materializer.recoverStalePrivateStagingBundles(
            reservationRegistry: registry,
            staleAfter: 60,
            now: now
        )
        #expect(
            first
                == ContainerRootFSMaterializer.maximumStagingRecoveriesPerPass
        )
        #expect(stagingBundles(in: root).count == 1)

        let second = await materializer.recoverStalePrivateStagingBundles(
            reservationRegistry: registry,
            staleAfter: 60,
            now: now
        )
        #expect(second == 1)
        #expect(stagingBundles(in: root).isEmpty)
    }

    @Test("staging recovery cannot remove an active pre-publication attempt")
    func activeMaterializationExcludesStagingRecovery() async throws {
        let root = try makeTemporaryAppRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let reservation = await registry.reserve(fixture.lease)
        let gate = MaterializationPublicationGate()
        let materializer = ContainerRootFSMaterializer(
            appSupportURL: root,
            beforePublish: { staging, final in
                gate.pause(staging: staging, final: final)
            }
        )
        let now = Date()
        let task = Task.detached {
            try materializer.materialize(
                snapshot: try makeSourceFilesystem(in: root),
                containerID: "active-scavenger-race",
                readOnly: false,
                reservation: reservation,
                createdAt: now.addingTimeInterval(-3_600)
            )
        }
        await gate.waitUntilPaused()

        let recovered = await materializer.recoverStalePrivateStagingBundles(
            reservationRegistry: registry,
            staleAfter: 60,
            now: now
        )
        #expect(recovered == 0)
        #expect(gate.paths().map { FileManager.default.fileExists(atPath: $0.staging.path) } == true)

        gate.resume()
        let prepared = try await task.value
        #expect(FileManager.default.fileExists(atPath: prepared.filesystem.source))
        #expect(stagingBundles(in: root).isEmpty)
        prepared.rollback()
        await registry.release(reservation)
    }

    @Test("an existing final bundle is never replaced by publication")
    func existingBundleIsPreserved() async throws {
        let root = try makeTemporaryAppRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let final = root.appendingPathComponent(
            "containers/existing-final",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: final,
            withIntermediateDirectories: false
        )
        let sentinel = final.appendingPathComponent("native-state")
        try Data("must-survive".utf8).write(to: sentinel)
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let reservation = await registry.reserve(fixture.lease)

        #expect(
            throws:
                ContainerRootFSMaterializationError
                .containerBundleExists("existing-final")
        ) {
            _ = try ContainerRootFSMaterializer(
                appSupportURL: root
            ).materialize(
                snapshot: try makeSourceFilesystem(in: root),
                containerID: "existing-final",
                readOnly: false,
                reservation: reservation
            )
        }

        #expect(try Data(contentsOf: sentinel) == Data("must-survive".utf8))
        #expect(PreparedContainerRootFS.ownership(at: final) == nil)
        #expect(stagingBundles(in: root).isEmpty)
    }

    @Test("concurrent publication has exactly one winner and no partial losers")
    func concurrentMaterializationPublishesOneCompleteBundle() async throws {
        let root = try makeTemporaryAppRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let reservation = await registry.reserve(fixture.lease)
        let materializer = ContainerRootFSMaterializer(appSupportURL: root)
        let source = try makeSourceFilesystem(in: root)

        let outcomes = await withTaskGroup(
            of: RootFSMaterializationOutcome.self,
            returning: [RootFSMaterializationOutcome].self
        ) { group in
            for _ in 0..<16 {
                group.addTask {
                    do {
                        return .published(
                            try materializer.materialize(
                                snapshot: source,
                                containerID: "concurrent-final",
                                readOnly: false,
                                reservation: reservation
                            )
                        )
                    } catch ContainerRootFSMaterializationError
                        .containerBundleExists
                    {
                        return .alreadyExists
                    } catch {
                        return .unexpected("\(error)")
                    }
                }
            }

            var results: [RootFSMaterializationOutcome] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        let published: [PreparedContainerRootFS] = outcomes.compactMap { outcome in
            guard case .published(let prepared) = outcome else { return nil }
            return prepared
        }
        let existsCount = outcomes.count(where: { outcome in
            if case .alreadyExists = outcome { return true }
            return false
        })
        let unexpected: [String] = outcomes.compactMap { outcome in
            guard case .unexpected(let error) = outcome else { return nil }
            return error
        }
        #expect(published.count == 1)
        #expect(existsCount == 15)
        #expect(unexpected.isEmpty)
        #expect(stagingBundles(in: root).isEmpty)
        if let winner = published.first {
            #expect(
                PreparedContainerRootFS.ownership(
                    at: winner.bundleDirectory
                ) == winner.ownership
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: winner.filesystem.source
                )
            )
            winner.rollback()
        }
    }

    @Test("rollback removes only the matching owned pre-create bundle")
    func rollbackOwnedBundle() async throws {
        let root = try makeTemporaryAppRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let reservation = await registry.reserve(fixture.lease)
        let materializer = ContainerRootFSMaterializer(appSupportURL: root)
        let source = try makeSourceFilesystem(in: root)

        let prepared = try materializer.materialize(
            snapshot: source,
            containerID: "owned-rollback",
            readOnly: true,
            reservation: reservation
        )

        #expect(FileManager.default.fileExists(atPath: prepared.bundleDirectory.path))
        #expect(prepared.filesystem.options.contains("ro"))
        #expect(
            PreparedContainerRootFS.ownership(at: prepared.bundleDirectory)
                == prepared.ownership
        )
        prepared.rollback()
        #expect(!FileManager.default.fileExists(atPath: prepared.bundleDirectory.path))
    }

    @Test("markCommitted removes ownership marker and rollback preserves bundle")
    func committedBundleIsPreserved() async throws {
        let root = try makeTemporaryAppRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let reservation = await registry.reserve(fixture.lease)
        let materializer = ContainerRootFSMaterializer(appSupportURL: root)
        let prepared = try materializer.materialize(
            snapshot: try makeSourceFilesystem(in: root),
            containerID: "committed-bundle",
            readOnly: false,
            reservation: reservation
        )

        prepared.markCommitted()
        prepared.rollback()

        #expect(FileManager.default.fileExists(atPath: prepared.bundleDirectory.path))
        #expect(PreparedContainerRootFS.ownership(at: prepared.bundleDirectory) == nil)
    }

    @Test("active attempt blocks stale recovery; inactive absent attempt recovers")
    func activeReservationBlocksRecovery() async throws {
        let root = try makeTemporaryAppRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let reservation = await registry.reserve(fixture.lease)
        let materializer = ContainerRootFSMaterializer(appSupportURL: root)
        let createdAt = Date(timeIntervalSinceNow: -3_600)
        let prepared = try materializer.materialize(
            snapshot: try makeSourceFilesystem(in: root),
            containerID: "stale-owned",
            readOnly: false,
            reservation: reservation,
            createdAt: createdAt
        )
        let expected = makeConfiguration(
            id: "stale-owned",
            image: fixture.lease.image.description
        )
        let absent = FakeNativeContainerCreator(behavior: .lookupAbsent)

        let blocked = await ContainerCreateRoute.recoverStalePreCreateBundle(
            containerID: expected.id,
            expectedConfiguration: expected,
            rootFSMaterializer: materializer,
            reservationRegistry: registry,
            nativeContainerCreator: absent,
            logger: Logger(label: "test"),
            staleAfter: 60,
            now: Date()
        )
        #expect(!blocked)
        #expect(FileManager.default.fileExists(atPath: prepared.bundleDirectory.path))

        await registry.release(reservation)
        let recovered = await ContainerCreateRoute.recoverStalePreCreateBundle(
            containerID: expected.id,
            expectedConfiguration: expected,
            rootFSMaterializer: materializer,
            reservationRegistry: registry,
            nativeContainerCreator: absent,
            logger: Logger(label: "test"),
            staleAfter: 60,
            now: Date()
        )
        #expect(recovered)
        #expect(!FileManager.default.fileExists(atPath: prepared.bundleDirectory.path))
    }

    @Test("native container ownership blocks stale bundle removal")
    func nativeContainerBlocksRecovery() async throws {
        let root = try makeTemporaryAppRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let reservation = await registry.reserve(fixture.lease)
        let materializer = ContainerRootFSMaterializer(appSupportURL: root)
        let prepared = try materializer.materialize(
            snapshot: try makeSourceFilesystem(in: root),
            containerID: "native-owner",
            readOnly: false,
            reservation: reservation,
            createdAt: Date(timeIntervalSinceNow: -3_600)
        )
        await registry.release(reservation)
        let expected = makeConfiguration(
            id: "native-owner",
            image: fixture.lease.image.description
        )
        let native = FakeNativeContainerCreator(
            behavior: .lookupSnapshot(expected)
        )

        let recovered = await ContainerCreateRoute.recoverStalePreCreateBundle(
            containerID: expected.id,
            expectedConfiguration: expected,
            rootFSMaterializer: materializer,
            reservationRegistry: registry,
            nativeContainerCreator: native,
            logger: Logger(label: "test"),
            staleAfter: 60,
            now: Date()
        )

        #expect(!recovered)
        #expect(FileManager.default.fileExists(atPath: prepared.bundleDirectory.path))
    }

    @Test("persisted Apple runtime configuration blocks stale bundle removal")
    func persistedNativeConfigurationBlocksRecovery() async throws {
        let root = try makeTemporaryAppRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let reservation = await registry.reserve(fixture.lease)
        let materializer = ContainerRootFSMaterializer(appSupportURL: root)
        let prepared = try materializer.materialize(
            snapshot: try makeSourceFilesystem(in: root),
            containerID: "persisted-native",
            readOnly: false,
            reservation: reservation,
            createdAt: Date(timeIntervalSinceNow: -3_600)
        )
        await registry.release(reservation)
        try Data("native-state".utf8).write(
            to: prepared.bundleDirectory.appendingPathComponent(
                "runtime-configuration.json"
            )
        )
        let expected = makeConfiguration(
            id: "persisted-native",
            image: fixture.lease.image.description
        )

        let recovered = await ContainerCreateRoute.recoverStalePreCreateBundle(
            containerID: expected.id,
            expectedConfiguration: expected,
            rootFSMaterializer: materializer,
            reservationRegistry: registry,
            nativeContainerCreator: FakeNativeContainerCreator(
                behavior: .lookupAbsent
            ),
            logger: Logger(label: "test"),
            staleAfter: 60,
            now: Date()
        )

        #expect(!recovered)
        #expect(FileManager.default.fileExists(atPath: prepared.bundleDirectory.path))
    }
}

@Suite("Interrupted create rootfs settlement")
struct InterruptedCreateSettlementTests {
    @Test("late exact commit preserves bundle and releases through reconciler")
    func lateCommitPreservesBundle() async throws {
        let setup = try await makePreparedRootFS(id: "late-commit")
        defer { try? FileManager.default.removeItem(at: setup.root) }
        let configuration = makeConfiguration(
            id: "late-commit",
            image: setup.fixture.lease.image.description
        )
        let reconciler = RecordingLeaseReconciler()
        let committer = NativeContainerCreateCommitter(
            client: FakeNativeContainerCreator(
                behavior: .throwAfterCommit(.interrupted)
            ),
            mutationCoordinator: ImageMutationCoordinator(),
            leaseManager: RecordingLeaseManager(),
            reconciliationAttempts: 1,
            reconciliationDelay: .zero
        )

        await ContainerCreateRoute.settleIndeterminateCreate(
            expected: configuration,
            options: .default,
            kernel: testKernel(),
            lease: setup.fixture.lease,
            preparedRootFS: setup.prepared,
            rootDescriptor: setup.fixture.lease.image.descriptor,
            reservation: setup.reservation,
            committer: committer,
            leaseReconciler: reconciler,
            logger: Logger(label: "test"),
            retryDelay: .zero
        )

        #expect(FileManager.default.fileExists(atPath: setup.prepared.bundleDirectory.path))
        #expect(PreparedContainerRootFS.ownership(at: setup.prepared.bundleDirectory) == nil)
        #expect(await reconciler.callCount == 1)
    }

    @Test("serialized retry server failure rolls back owned bundle")
    func definitiveRetryFailureRollsBack() async throws {
        let setup = try await makePreparedRootFS(id: "stale-absence")
        defer { try? FileManager.default.removeItem(at: setup.root) }
        let configuration = makeConfiguration(
            id: "stale-absence",
            image: setup.fixture.lease.image.description
        )
        let reconciler = RecordingLeaseReconciler()
        let committer = NativeContainerCreateCommitter(
            client: FakeNativeContainerCreator(
                behavior: .fail(.invalidArgument)
            ),
            mutationCoordinator: ImageMutationCoordinator(),
            leaseManager: RecordingLeaseManager(),
            reconciliationAttempts: 1,
            reconciliationDelay: .zero
        )

        await ContainerCreateRoute.settleIndeterminateCreate(
            expected: configuration,
            options: .default,
            kernel: testKernel(),
            lease: setup.fixture.lease,
            preparedRootFS: setup.prepared,
            rootDescriptor: setup.fixture.lease.image.descriptor,
            reservation: setup.reservation,
            committer: committer,
            leaseReconciler: reconciler,
            logger: Logger(label: "test"),
            retryDelay: .zero
        )

        #expect(!FileManager.default.fileExists(atPath: setup.prepared.bundleDirectory.path))
        #expect(await reconciler.callCount == 1)
    }
}

private struct ImageLeaseFixture: Sendable {
    let lease: ContainerImageLease

    init(hex: Character = "1") {
        let digest = "sha256:" + String(repeating: String(hex), count: 64)
        lease = ContainerImageLease(
            image: ClientImage(
                description: ImageDescription(
                    reference: ContainerImageLease.reference(for: digest),
                    descriptor: Descriptor(
                        mediaType: MediaTypes.index,
                        digest: digest,
                        size: 1
                    )
                )
            )
        )
    }
}

private actor RecordingLeaseManager: ContainerImageLeasing {
    private(set) var verifyCount = 0

    func acquire(for resolved: ResolvedImageIdentity) async throws
        -> ContainerImageLease
    {
        fatalError("unused")
    }

    func verify(_ lease: ContainerImageLease) async throws {
        verifyCount += 1
    }

    func release(_ lease: ContainerImageLease) async throws {}
}

private actor RecordingLeaseReconciler: ContainerImageLeaseReconciling {
    private(set) var callCount = 0
    private(set) var lastReservationID: UUID?

    func reconcile(
        rootDescriptor: Descriptor,
        releasing reservation: ContainerImageLeaseReservation?
    ) async {
        callCount += 1
        lastReservationID = reservation?.reservationID
    }
}

private actor FakeNativeContainerCreator: NativeContainerCreating {
    enum Behavior: Sendable {
        case throwAfterCommit(ContainerizationError.Code)
        case throwWithConflictingCommit(ImageDescription)
        case fail(ContainerizationError.Code)
        case lookupSnapshot(ContainerConfiguration)
        case lookupAbsent
    }

    private let behavior: Behavior
    private var snapshot: ContainerSnapshot?

    init(behavior: Behavior) {
        self.behavior = behavior
        if case .lookupSnapshot(let configuration) = behavior {
            snapshot = ContainerSnapshot(
                configuration: configuration,
                status: .stopped,
                networks: []
            )
        }
    }

    func create(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions,
        kernel: Kernel
    ) async throws {
        switch behavior {
        case .throwAfterCommit(let code):
            snapshot = ContainerSnapshot(
                configuration: configuration,
                status: .stopped,
                networks: []
            )
            throw ContainerizationError(code, message: "injected create error")
        case .throwWithConflictingCommit(let image):
            var conflicting = configuration
            conflicting.image = image
            snapshot = ContainerSnapshot(
                configuration: conflicting,
                status: .stopped,
                networks: []
            )
            throw ContainerizationError(.interrupted, message: "injected")
        case .fail(let code):
            throw ContainerizationError(code, message: "injected create error")
        case .lookupSnapshot, .lookupAbsent:
            throw ContainerizationError(
                .invalidState,
                message: "create is unused by lookup-only fake"
            )
        }
    }

    func get(id: String) async throws -> ContainerSnapshot {
        guard let snapshot else {
            throw ContainerizationError(.notFound, message: "not found")
        }
        return snapshot
    }
}

private actor BooleanProbe {
    private(set) var value = false

    func setTrue() {
        value = true
    }
}

private actor AsyncTestGate {
    private var entered = false
    private var openState = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !openState else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func open() {
        openState = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class MaterializationPublicationGate: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stagingPath: URL?
    private var finalPath: URL?

    func pause(staging: URL, final: URL) {
        lock.lock()
        stagingPath = staging
        finalPath = final
        lock.unlock()
        reached.signal()
        proceed.wait()
    }

    func waitUntilPaused() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.reached.wait()
                continuation.resume()
            }
        }
    }

    func paths() -> (staging: URL, final: URL)? {
        lock.lock()
        defer { lock.unlock() }
        guard let stagingPath, let finalPath else { return nil }
        return (stagingPath, finalPath)
    }

    func resume() {
        proceed.signal()
    }
}

private enum RootFSMaterializationOutcome: Sendable {
    case published(PreparedContainerRootFS)
    case alreadyExists
    case unexpected(String)
}

private func stagingBundles(in appRoot: URL) -> [String] {
    let containers = appRoot.appendingPathComponent(
        "containers",
        isDirectory: true
    )
    let contents =
        (try? FileManager.default.contentsOfDirectory(
            atPath: containers.path
        )) ?? []
    return contents.filter {
        $0.hasPrefix(ContainerRootFSMaterializer.stagingBundlePrefix)
    }
}

private func makePrivateStagingBundle(
    in appRoot: URL,
    name: String =
        "\(ContainerRootFSMaterializer.stagingBundlePrefix)\(UUID().uuidString)",
    ownership: PreparedContainerRootFS.Ownership? = nil,
    markerData: Data? = nil
) throws -> URL {
    let directory = appRoot.appendingPathComponent(
        "containers/\(name)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    let encoded = try markerData ?? ownership.map { try encodedOwnership($0) }
    if let encoded {
        try encoded.write(
            to: directory.appendingPathComponent(
                PreparedContainerRootFS.ownershipMarkerFilename
            )
        )
    }
    return directory
}

private func encodedOwnership(
    _ ownership: PreparedContainerRootFS.Ownership,
    formatVersion: Int? = nil
) throws -> Data {
    let encoded = try JSONEncoder().encode(ownership)
    guard let formatVersion else { return encoded }
    guard
        var object = try JSONSerialization.jsonObject(with: encoded)
            as? [String: Any]
    else {
        throw CocoaError(.coderInvalidValue)
    }
    object["formatVersion"] = formatVersion
    return try JSONSerialization.data(withJSONObject: object)
}

private func makeConfiguration(
    id: String,
    image: ImageDescription
) -> ContainerConfiguration {
    let process = ProcessConfiguration(
        executable: "/bin/true",
        arguments: [],
        environment: [],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0)
    )
    return ContainerConfiguration(id: id, image: image, process: process)
}

private func testKernel() -> Kernel {
    Kernel(
        path: URL(fileURLWithPath: "/tmp/socktainer-test-kernel"),
        platform: .current
    )
}

private func makeTemporaryAppRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "socktainer-create-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("containers", isDirectory: true),
        withIntermediateDirectories: true
    )
    return root
}

private func makeSourceFilesystem(in root: URL) throws -> Filesystem {
    let source = root.appendingPathComponent(
        "source-\(UUID().uuidString).ext4",
        isDirectory: false
    )
    try Data(repeating: 0x5a, count: 4_096).write(to: source)
    return .block(
        format: "ext4",
        source: source.path,
        destination: "/",
        options: []
    )
}

private func makePreparedRootFS(
    id: String
) async throws -> (
    root: URL,
    fixture: ImageLeaseFixture,
    reservation: ContainerImageLeaseReservation,
    prepared: PreparedContainerRootFS
) {
    let root = try makeTemporaryAppRoot()
    do {
        let fixture = ImageLeaseFixture()
        let registry = ContainerImageLeaseReservationRegistry()
        let reservation = await registry.reserve(fixture.lease)
        let prepared = try ContainerRootFSMaterializer(
            appSupportURL: root
        ).materialize(
            snapshot: try makeSourceFilesystem(in: root),
            containerID: id,
            readOnly: false,
            reservation: reservation
        )
        return (root, fixture, reservation, prepared)
    } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}
