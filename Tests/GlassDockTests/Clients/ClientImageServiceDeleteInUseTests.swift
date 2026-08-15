import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Logging
import Testing

@testable import GlassDock

@Suite("ClientImageService delete — containers retain immutable roots")
struct ClientImageServiceDeleteInUseTests {
    @Test("the final tag, root, manifest, and config reference conflict while a stopped container owns the root")
    func finalReferenceConflictsForEveryIdentity() async throws {
        for identity in DeleteIdentity.allCases {
            let fixture = DeleteInUseFixture(
                tags: [DeleteInUseFixture.primaryTag],
                status: .stopped
            )

            do {
                _ = try await fixture.service.delete(
                    id: fixture.identifier(identity),
                    force: false
                )
                Issue.record("expected \(identity) deletion to conflict")
            } catch ClientImageError.conflict(let message) {
                #expect(message.contains("must be forced"))
                #expect(message.contains("stopped container fixture-container"))
            } catch {
                Issue.record("unexpected \(identity) deletion error: \(error)")
            }

            let images = await fixture.store.imagesByReference()
            #expect(Set(images.keys) == Set([DeleteInUseFixture.primaryTag]))
            #expect(await fixture.store.cleanupCount == 0)
        }
    }

    @Test("force can untag an explicit repository reference used by a running container")
    func forcedTagRetainsLeaseForRunningContainer() async throws {
        let fixture = DeleteInUseFixture(
            tags: [DeleteInUseFixture.primaryTag],
            status: .running
        )

        let result = try await fixture.service.delete(
            id: DeleteInUseFixture.primaryTag,
            force: true
        )

        let images = await fixture.store.imagesByReference()
        let lease = ContainerImageLease.reference(for: fixture.rootDigest)
        #expect(Set(images.keys) == Set([lease]))
        #expect(images[lease]?.digest == fixture.rootDigest)
        #expect(result.deletedDigest == nil)
        #expect(await fixture.store.cleanupCount == 1)
    }

    @Test("force cannot delete an immutable image ID used by a running container")
    func forcedImmutableIDConflictsWithoutMutation() async throws {
        for identity in [
            DeleteIdentity.root, .manifest, .config,
        ] {
            let fixture = DeleteInUseFixture(
                tags: [DeleteInUseFixture.primaryTag],
                status: .running
            )

            do {
                _ = try await fixture.service.delete(
                    id: fixture.identifier(identity),
                    force: true
                )
                Issue.record("expected hard conflict for \(identity)")
            } catch ClientImageError.conflict(let message) {
                #expect(message.contains("cannot be forced"))
                #expect(message.contains("running container fixture-container"))
            } catch {
                Issue.record("unexpected \(identity) error: \(error)")
            }

            let images = await fixture.store.imagesByReference()
            #expect(Set(images.keys) == [DeleteInUseFixture.primaryTag])
            #expect(await fixture.store.cleanupCount == 0)
        }
    }

    @Test("deleting one sibling tag is allowed and keeps both the sibling and container lease")
    func siblingTagAllowsUntagAndRetainsLease() async throws {
        let fixture = DeleteInUseFixture(
            tags: [
                DeleteInUseFixture.primaryTag,
                DeleteInUseFixture.siblingTag,
            ],
            status: .stopped
        )

        let result = try await fixture.service.delete(
            id: DeleteInUseFixture.primaryTag,
            force: false
        )

        let images = await fixture.store.imagesByReference()
        let lease = ContainerImageLease.reference(for: fixture.rootDigest)
        #expect(images[DeleteInUseFixture.primaryTag] == nil)
        #expect(images[DeleteInUseFixture.siblingTag]?.digest == fixture.rootDigest)
        #expect(images[lease]?.digest == fixture.rootDigest)
        #expect(result.untaggedReferences == [DeleteInUseFixture.primaryTag])
        #expect(result.deletedDigest == nil)
    }

    @Test("deleting config A's final tag preserves the shared root lease owned by config B")
    func deletingConfigAPreservesConfigBRootLease() async throws {
        let lease = ContainerImageLease.reference(
            for: DeleteInUseFixture.rootDigestValue
        )
        for status in [RuntimeStatus.running, .stopped] {
            let fixture = DeleteInUseFixture(
                tags: [DeleteInUseFixture.primaryTag, lease],
                status: status,
                cleanupBytes: 4_096,
                includeOtherVariant: true,
                containerConfigDigest:
                    DeleteInUseFixture.otherConfigDigestValue
            )

            // Config A and config B are independently selectable Docker image
            // identities inside one physical Apple OCI root. Config B must not
            // create a config-A conflict, but it still owns the root lease.
            let result = try await fixture.service.delete(
                id: fixture.configDigest,
                force: false
            )

            let images = await fixture.store.imagesByReference()
            #expect(Set(images.keys) == [lease])
            #expect(images[lease]?.digest == fixture.rootDigest)
            #expect(result.untaggedReferences == [DeleteInUseFixture.primaryTag])
            #expect(result.deletedDigest == nil)
            #expect(result.reclaimedBytes == 0)
            #expect(await fixture.store.cleanupCount == 1)
        }
    }

    @Test("deleting tag A preserves the shared root lease owned by config B")
    func deletingTagAPreservesConfigBRootLease() async throws {
        let lease = ContainerImageLease.reference(
            for: DeleteInUseFixture.rootDigestValue
        )
        for status in [RuntimeStatus.running, .stopped] {
            let fixture = DeleteInUseFixture(
                tags: [DeleteInUseFixture.primaryTag, lease],
                status: status,
                cleanupBytes: 4_096,
                includeOtherVariant: true,
                containerConfigDigest:
                    DeleteInUseFixture.otherConfigDigestValue
            )

            let result = try await fixture.service.delete(
                id: DeleteInUseFixture.primaryTag,
                force: false
            )

            let images = await fixture.store.imagesByReference()
            #expect(Set(images.keys) == [lease])
            #expect(images[lease]?.digest == fixture.rootDigest)
            #expect(result.deletedDigest == nil)
            #expect(result.reclaimedBytes == 0)
            #expect(await fixture.store.cleanupCount == 1)
        }
    }

    @Test("forced digest deletion against a running container never partially untags siblings")
    func forcedDigestWithRunningContainerIsAtomicConflict() async throws {
        let fixture = DeleteInUseFixture(
            tags: [
                DeleteInUseFixture.primaryTag,
                DeleteInUseFixture.siblingTag,
            ],
            status: .running
        )

        await #expect(throws: ClientImageError.self) {
            try await fixture.service.delete(
                id: fixture.configDigest,
                force: true
            )
        }

        let images = await fixture.store.imagesByReference()
        #expect(
            Set(images.keys)
                == Set([
                    DeleteInUseFixture.primaryTag,
                    DeleteInUseFixture.siblingTag,
                ]))
        #expect(await fixture.store.cleanupCount == 0)
    }

    @Test("non-force digest deletion with sibling tags makes no partial mutation")
    func nonForcedDigestWithSiblingTagsConflictsAtomically() async throws {
        let fixture = DeleteInUseFixture(
            tags: [
                DeleteInUseFixture.primaryTag,
                DeleteInUseFixture.siblingTag,
            ],
            status: .stopped
        )

        await #expect(throws: ClientImageError.self) {
            try await fixture.service.delete(
                id: fixture.manifestDigest,
                force: false
            )
        }

        let images = await fixture.store.imagesByReference()
        #expect(
            Set(images.keys)
                == Set([
                    DeleteInUseFixture.primaryTag,
                    DeleteInUseFixture.siblingTag,
                ]))
        #expect(await fixture.store.cleanupCount == 0)
    }

    @Test("prune deletes a hidden dangling root by exact physical identity and reports actual GC bytes")
    func pruneDeletesExactDanglingRoot() async throws {
        let rootDigest = DeleteInUseFixture.rootDigestValue
        let dangling = "moby-dangling@\(rootDigest)"
        let fixture = DeleteInUseFixture(
            tags: [dangling],
            status: nil,
            cleanupBytes: 4_096
        )

        let result = try await fixture.service.prune(
            filters: [:],
            logger: Logger(label: "delete-in-use-prune-test")
        )

        #expect(await fixture.store.imagesByReference().isEmpty)
        #expect(result.results.count == 1)
        #expect(result.results.first?.untagged == dangling)
        #expect(result.results.first?.deletedDigest == fixture.configDigest)
        #expect(result.results.first?.reclaimedBytes == 4_096)
        #expect(result.spaceReclaimed == 4_096)
    }

    @Test("prune reconciles a stale runtime lease with no owning container")
    func pruneReconcilesStaleRuntimeLease() async throws {
        let rootDigest = DeleteInUseFixture.rootDigestValue
        let lease = ContainerImageLease.reference(for: rootDigest)
        let fixture = DeleteInUseFixture(
            tags: [lease],
            status: nil,
            cleanupBytes: 4_096
        )

        let result = try await fixture.service.prune(
            filters: [:],
            logger: Logger(label: "delete-in-use-stale-lease-prune-test")
        )

        #expect(await fixture.store.imagesByReference().isEmpty)
        #expect(result.results.count == 1)
        #expect(result.results.first?.deletedDigest == fixture.configDigest)
        #expect(result.spaceReclaimed == 4_096)
        #expect(await fixture.store.cleanupCount == 1)
    }

    @Test("prune preserves a runtime lease while a stopped container owns its root")
    func prunePreservesActiveRuntimeLease() async throws {
        let rootDigest = DeleteInUseFixture.rootDigestValue
        let lease = ContainerImageLease.reference(for: rootDigest)
        let fixture = DeleteInUseFixture(
            tags: [lease],
            status: .stopped,
            cleanupBytes: 4_096
        )

        let result = try await fixture.service.prune(
            filters: ["dangling": ["false"]],
            logger: Logger(label: "delete-in-use-active-lease-prune-test")
        )

        #expect(await fixture.store.imagesByReference()[lease]?.digest == rootDigest)
        #expect(result.results.isEmpty)
        #expect(result.spaceReclaimed == 0)
        #expect(await fixture.store.cleanupCount == 0)
    }

    @Test("prune preserves a runtime lease while container create owns an in-flight reservation")
    func prunePreservesReservedRuntimeLease() async throws {
        let rootDigest = DeleteInUseFixture.rootDigestValue
        let lease = ContainerImageLease.reference(for: rootDigest)
        let fixture = DeleteInUseFixture(
            tags: [lease],
            status: nil,
            cleanupBytes: 4_096
        )
        let reservation = try await fixture.reserveRootLease()

        let result = try await fixture.service.prune(
            filters: ["dangling": ["false"]],
            logger: Logger(label: "delete-in-use-reserved-lease-prune-test")
        )

        #expect(await fixture.store.imagesByReference()[lease]?.digest == rootDigest)
        #expect(result.results.isEmpty)
        #expect(result.spaceReclaimed == 0)
        #expect(await fixture.store.cleanupCount == 0)
        await fixture.reservations.release(reservation)
    }

    @Test("delete conflicts with an in-flight create unless forced and always preserves its exact lease")
    func deleteHonorsInFlightCreateReservation() async throws {
        let fixture = DeleteInUseFixture(
            tags: [DeleteInUseFixture.primaryTag],
            status: nil
        )
        let reservation = try await fixture.reserveRootLease()

        do {
            _ = try await fixture.service.delete(
                id: DeleteInUseFixture.primaryTag,
                force: false
            )
            Issue.record("expected final reference deletion to conflict")
        } catch ClientImageError.conflict(let message) {
            #expect(message.contains("must be forced"))
            #expect(message.contains("in-progress container create"))
        }

        let result = try await fixture.service.delete(
            id: DeleteInUseFixture.primaryTag,
            force: true
        )
        let lease = ContainerImageLease.reference(for: fixture.rootDigest)
        let images = await fixture.store.imagesByReference()
        #expect(Set(images.keys) == [lease])
        #expect(result.deletedDigest == nil)
        await fixture.reservations.release(reservation)
    }
}

private enum DeleteIdentity: String, CaseIterable, CustomStringConvertible {
    case tag
    case root
    case manifest
    case config

    var description: String { rawValue }
}

private struct DeleteInUseFixture {
    static let primaryTag = "docker.io/library/delete-in-use:latest"
    static let siblingTag = "docker.io/library/delete-in-use:retained"
    static let rootDigestValue =
        "sha256:" + String(repeating: "1", count: 64)
    static let otherManifestDigestValue =
        "sha256:" + String(repeating: "4", count: 64)
    static let otherConfigDigestValue =
        "sha256:" + String(repeating: "5", count: 64)

    let rootDigest = Self.rootDigestValue
    let manifestDigest = "sha256:" + String(repeating: "2", count: 64)
    let configDigest = "sha256:" + String(repeating: "3", count: 64)
    let store: DeleteInUseImageStore
    let reservations: ContainerImageLeaseReservationRegistry
    let service: ClientImageService

    init(
        tags: [String],
        status: RuntimeStatus?,
        cleanupBytes: UInt64 = 0,
        includeOtherVariant: Bool = false,
        containerConfigDigest: String? = nil
    ) {
        let rootDigest = self.rootDigest
        let manifestDigest = self.manifestDigest
        let configDigest = self.configDigest
        let rootDescriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: rootDigest,
            size: 100
        )
        let images = tags.map {
            ClientImage(
                description: ImageDescription(
                    reference: $0,
                    descriptor: rootDescriptor
                )
            )
        }
        var manifestDescriptors = [
            Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: manifestDigest,
                size: 80,
                platform: Platform(arch: "arm64", os: "linux")
            )
        ]
        if includeOtherVariant {
            manifestDescriptors.append(
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: Self.otherManifestDigestValue,
                    size: 80,
                    platform: Platform(arch: "amd64", os: "linux")
                )
            )
        }
        let index = Index(
            manifests: manifestDescriptors
        )
        let manifest = Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: configDigest,
                size: 20
            ),
            layers: []
        )
        let config = ContainerizationOCI.Image(
            created: "2026-08-07T12:00:00Z",
            architecture: "arm64",
            os: "linux",
            config: ImageConfig(),
            rootfs: Rootfs(type: "layers", diffIDs: [])
        )
        let otherManifest = Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: Self.otherConfigDigestValue,
                size: 20
            ),
            layers: []
        )
        let otherConfig = ContainerizationOCI.Image(
            created: "2026-08-07T12:00:00Z",
            architecture: "amd64",
            os: "linux",
            config: ImageConfig(),
            rootfs: Rootfs(type: "layers", diffIDs: [])
        )
        let store = DeleteInUseImageStore(
            images: images,
            index: index,
            manifestDigest: manifestDigest,
            manifest: manifest,
            configDigest: configDigest,
            config: config,
            additionalManifests: includeOtherVariant
                ? [Self.otherManifestDigestValue: otherManifest] : [:],
            additionalConfigs: includeOtherVariant
                ? [Self.otherConfigDigestValue: otherConfig] : [:],
            cleanupBytes: cleanupBytes
        )
        let coordinator = ImageMutationCoordinator()
        let resolver = ImageIdentityResolver(
            systemConfig: ContainerSystemConfig(),
            catalog: store,
            mutationCoordinator: coordinator
        )
        let containers =
            status.map {
                [
                    Self.container(
                        rootDescriptor: rootDescriptor,
                        status: $0,
                        configDigest: containerConfigDigest,
                        platform: containerConfigDigest
                            == Self.otherConfigDigestValue
                            ? Platform(arch: "amd64", os: "linux") : nil
                    )
                ]
            } ?? []
        let reservations = ContainerImageLeaseReservationRegistry()

        self.store = store
        self.reservations = reservations
        self.service = ClientImageService(
            containerSystemConfig: ContainerSystemConfig(),
            identityResolver: resolver,
            mutationCoordinator: coordinator,
            referenceStore: store,
            runnableImageSelector: RunnableImageSelector(
                contentProvider: store
            ),
            containerInventoryProvider: StaticImageContainerInventoryProvider(
                snapshots: containers
            ),
            imageLeaseReservations: reservations
        )
    }

    func reserveRootLease() async throws -> ContainerImageLeaseReservation {
        let reference = ContainerImageLease.reference(for: rootDigest)
        let image: ClientImage
        if let existing = await store.imagesByReference()[reference] {
            image = existing
        } else {
            image = try await store.tag(
                existing: Self.primaryTag,
                new: reference
            )
        }
        return await reservations.reserve(ContainerImageLease(image: image))
    }

    func identifier(_ identity: DeleteIdentity) -> String {
        switch identity {
        case .tag: Self.primaryTag
        case .root: rootDigest
        case .manifest: manifestDigest
        case .config: configDigest
        }
    }

    private static func container(
        rootDescriptor: Descriptor,
        status: RuntimeStatus,
        configDigest: String? = nil,
        platform: Platform? = nil
    ) -> ContainerSnapshot {
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
        let image = ImageDescription(
            reference: ContainerImageLease.reference(
                for: rootDescriptor.digest
            ),
            descriptor: rootDescriptor
        )
        var configuration = ContainerConfiguration(
            id: "fixture-container",
            image: image,
            process: process
        )
        if let configDigest {
            configuration.labels[
                ContainerImageIdentity.configDigestLabel
            ] = configDigest
        }
        if let platform {
            configuration.platform = platform
        }
        return ContainerSnapshot(
            configuration: configuration,
            status: status,
            networks: []
        )
    }
}

private struct StaticImageContainerInventoryProvider:
    ContainerSnapshotInventoryProviding
{
    let snapshots: [ContainerSnapshot]

    func containers() async throws -> [ContainerSnapshot] {
        snapshots
    }
}

private enum DeleteInUseStoreError: Error {
    case missingReference(String)
}

private actor DeleteInUseImageStore: ImageReferenceStore,
    ImageIdentityCatalog, RunnableImageContentProviding
{
    private var images: [String: ClientImage]
    private let storedIndex: Index
    private let storedManifests: [String: Manifest]
    private let storedConfigs: [String: ContainerizationOCI.Image]
    private let cleanupBytes: UInt64
    private(set) var cleanupCount = 0

    init(
        images: [ClientImage],
        index: Index,
        manifestDigest: String,
        manifest: Manifest,
        configDigest: String,
        config: ContainerizationOCI.Image,
        additionalManifests: [String: Manifest] = [:],
        additionalConfigs: [String: ContainerizationOCI.Image] = [:],
        cleanupBytes: UInt64
    ) {
        self.images = Dictionary(
            uniqueKeysWithValues: images.map { ($0.reference, $0) }
        )
        self.storedIndex = index
        self.storedManifests = additionalManifests.merging([
            manifestDigest: manifest
        ]) { _, primary in primary }
        self.storedConfigs = additionalConfigs.merging([
            configDigest: config
        ]) { _, primary in primary }
        self.cleanupBytes = cleanupBytes
    }

    func list() async throws -> [ClientImage] {
        Array(images.values)
    }

    func tag(existing: String, new: String) async throws -> ClientImage {
        guard let source = images[existing] else {
            throw DeleteInUseStoreError.missingReference(existing)
        }
        let tagged = ClientImage(
            description: ImageDescription(
                reference: new,
                descriptor: source.descriptor
            )
        )
        images[new] = tagged
        return tagged
    }

    func delete(reference: String) async throws {
        guard images.removeValue(forKey: reference) != nil else {
            throw DeleteInUseStoreError.missingReference(reference)
        }
    }

    func cleanUpOrphanedBlobs() async throws -> UInt64 {
        cleanupCount += 1
        return cleanupBytes
    }

    func index(for image: ClientImage) async throws -> Index {
        storedIndex
    }

    func manifest(digest: String) async throws -> Manifest? {
        storedManifests[digest]
    }

    func config(digest: String) async throws -> ContainerizationOCI.Image? {
        storedConfigs[digest]
    }

    func imagesByReference() -> [String: ClientImage] {
        images
    }
}
