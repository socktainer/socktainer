import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerResource
import Containerization
import ContainerizationEXT4
import ContainerizationError
import ContainerizationOCI
import Darwin
import Foundation
import Logging

struct RunnableImageSnapshot: Sendable {
    let filesystem: Filesystem
    private let cleanupDirectory: URL?

    init(filesystem: Filesystem, cleanupDirectory: URL? = nil) {
        self.filesystem = filesystem
        self.cleanupDirectory = cleanupDirectory
    }

    /// Exact artifact-safe snapshots are staging files only. The materializer
    /// clones them into the container's final bundle and every handler exit
    /// (success, error, or cancellation) removes the staging directory.
    func cleanup() {
        guard let cleanupDirectory else { return }
        try? FileManager.default.removeItem(at: cleanupDirectory)
    }
}

protocol RunnableImageSnapshotProviding: Sendable {
    func snapshot(
        for image: ClientImage,
        variant: RunnableImageVariant,
        descriptors: [ResolvedImageDescriptor],
        logger: Logger
    ) async throws -> RunnableImageSnapshot
}

/// Chooses Apple's native snapshot path only when its platform-first lookup is
/// provably equivalent to the digest-selected runnable variant. Otherwise an
/// exact, one-manifest OCI root is unpacked into a unique staging directory.
/// There is deliberately no persistent second snapshot cache: the rare exact
/// path is cloned into the final container bundle and removed immediately.
struct LiveRunnableImageSnapshotProvider: RunnableImageSnapshotProviding {
    private let stagingRoot: URL
    private let contentStore = RemoteContentStoreClient()

    init(appSupportURL: URL) {
        stagingRoot = appSupportURL.appendingPathComponent(
            "glassdock/create-snapshots",
            isDirectory: true
        )
    }

    func snapshot(
        for image: ClientImage,
        variant: RunnableImageVariant,
        descriptors: [ResolvedImageDescriptor],
        logger: Logger
    ) async throws -> RunnableImageSnapshot {
        if !Self.requiresExactSnapshot(
            variant: variant,
            descriptors: descriptors
        ) {
            return RunnableImageSnapshot(
                filesystem: try await image.getCreateSnapshot(
                    platform: variant.platform
                )
            )
        }

        logger.info("Apple's platform-first image lookup does not select runnable manifest \(variant.descriptor.digest); preparing exact rootfs")
        return try await exactSnapshot(variant: variant)
    }

    static func requiresExactSnapshot(
        variant: RunnableImageVariant,
        descriptors: [ResolvedImageDescriptor]
    ) -> Bool {
        // Apple's native API only selects direct root descriptors by platform.
        // A recursively selected leaf cannot be named exactly through that API.
        // Any nested graph also makes a flattened descriptor view insufficient
        // to prove that Apple's first direct platform match is the same leaf.
        if variant.pathDepth > 1
            || descriptors.contains(where: { $0.pathDepth > 1 })
        {
            return true
        }
        guard
            let appleSelection = descriptors.first(where: {
                $0.descriptor.platform == variant.platform
            })
        else {
            return true
        }
        return appleSelection.runnableVariant?.descriptor
            != variant.descriptor
    }

    private func exactSnapshot(
        variant: RunnableImageVariant
    ) async throws -> RunnableImageSnapshot {
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: stagingRoot.path
        )
        let stagingDirectory = stagingRoot.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var handedOff = false
        defer {
            if !handedOff {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
        }

        let syntheticIndex = Index(manifests: [variant.descriptor])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let indexSize = try encoder.encode(syntheticIndex).count
        let ingested = try await contentStore.ingest { ingestDirectory in
            let writer = try ContentWriter(for: ingestDirectory)
            try writer.create(from: syntheticIndex)
        }
        guard let rawIndexDigest = ingested.first else {
            throw ContainerizationError(
                .internalError,
                message: "exact runnable index ingest returned no digest"
            )
        }
        let indexDigest =
            rawIndexDigest.hasPrefix("sha256:")
            ? rawIndexDigest : "sha256:\(rawIndexDigest)"
        let exactImage = Containerization.Image(
            description: .init(
                reference: "glassdock-exact@\(variant.descriptor.digest)",
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: indexDigest,
                    size: Int64(indexSize)
                )
            ),
            contentStore: contentStore
        )

        let snapshotURL = stagingDirectory.appendingPathComponent(
            "snapshot.ext4",
            isDirectory: false
        )
        let unpacker = EXT4Unpacker(
            capacityInBytes: 512 * 1024 * 1024 * 1024,
            journal: .init(defaultMode: .ordered)
        )
        let mount = try await unpacker.unpack(
            exactImage,
            for: variant.platform,
            at: snapshotURL,
            progress: nil
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: snapshotURL.path
        )
        try Task.checkCancellation()
        handedOff = true
        return RunnableImageSnapshot(
            filesystem: .block(
                format: mount.type,
                source: snapshotURL.path,
                destination: mount.destination,
                options: mount.options
            ),
            cleanupDirectory: stagingDirectory
        )
    }
}

struct PreparedContainerRootFS: Sendable {
    static let ownershipMarkerFilename = ".glassdock-create-owned"

    struct Ownership: Codable, Equatable, Sendable {
        static let currentFormatVersion = 1

        let formatVersion: Int
        let containerID: String
        let reservationID: UUID
        let leaseReference: String
        let rootDigest: String
        let createdAt: Date

        init(
            containerID: String,
            reservation: ContainerImageLeaseReservation,
            createdAt: Date = Date()
        ) {
            formatVersion = Self.currentFormatVersion
            self.containerID = containerID
            reservationID = reservation.reservationID
            leaseReference = reservation.leaseReference
            rootDigest = reservation.rootDigest
            self.createdAt = createdAt
        }
    }

    let filesystem: Filesystem
    let bundleDirectory: URL
    let ownership: Ownership

    func rollback() {
        guard Self.ownership(at: bundleDirectory) == ownership else { return }
        try? FileManager.default.removeItem(at: bundleDirectory)
    }

    func markCommitted() {
        guard Self.ownership(at: bundleDirectory) == ownership else { return }
        try? FileManager.default.removeItem(
            at: bundleDirectory.appendingPathComponent(
                Self.ownershipMarkerFilename,
                isDirectory: false
            )
        )
    }

    static func isOwnedPreCreateBundle(_ directory: URL) -> Bool {
        ownership(at: directory) != nil
    }

    static func ownership(at directory: URL) -> Ownership? {
        let marker = directory.appendingPathComponent(
            ownershipMarkerFilename,
            isDirectory: false
        )
        guard
            let data = try? Data(contentsOf: marker),
            let ownership = try? JSONDecoder().decode(
                Ownership.self,
                from: data
            ),
            ownership.formatVersion == Ownership.currentFormatVersion
        else {
            return nil
        }
        return ownership
    }
}

enum ContainerRootFSMaterializationError: Error, Equatable {
    case unsafeContainerID(String)
    case containerBundleExists(String)
}

/// Clones a read-only image snapshot into the container's own Apple bundle
/// before create, then supplies that per-container clone as `rootFsOverride`.
/// The override is essential: otherwise Apple's server repeats its unsafe
/// platform-first manifest lookup. An ownership marker makes rollback precise:
/// only a directory created by this attempt, before Apple commits it, is removed.
struct ContainerRootFSMaterializer: Sendable {
    static let stagingBundlePrefix = ".glassdock-create-staging-"
    /// Keep opportunistic crash recovery small enough that one container-create
    /// request cannot turn into an unbounded filesystem mutation. Additional
    /// stale bundles are picked up by later creates.
    static let maximumStagingRecoveriesPerPass = 32
    static let staleStagingBundleAge: TimeInterval = 10 * 60

    let appSupportURL: URL
    private let beforePublish: (@Sendable (_ stagingBundle: URL, _ finalBundle: URL) -> Void)?

    init(
        appSupportURL: URL,
        beforePublish:
            (@Sendable (_ stagingBundle: URL, _ finalBundle: URL) -> Void)? = nil
    ) {
        self.appSupportURL = appSupportURL
        self.beforePublish = beforePublish
    }

    func materialize(
        snapshot: Filesystem,
        containerID: String,
        readOnly: Bool,
        reservation: ContainerImageLeaseReservation,
        createdAt: Date = Date()
    ) throws -> PreparedContainerRootFS {
        let containersRoot = appSupportURL.appendingPathComponent(
            "containers",
            isDirectory: true
        ).standardizedFileURL
        let bundleDirectory = containersRoot.appendingPathComponent(
            containerID,
            isDirectory: true
        ).standardizedFileURL
        guard bundleDirectory.deletingLastPathComponent() == containersRoot
        else {
            throw ContainerRootFSMaterializationError.unsafeContainerID(
                containerID
            )
        }

        let stagingDirectory = try Self.createPrivateStagingBundle(
            in: containersRoot
        )
        var published = false
        var ownership: PreparedContainerRootFS.Ownership?

        do {
            let marker = stagingDirectory.appendingPathComponent(
                PreparedContainerRootFS.ownershipMarkerFilename,
                isDirectory: false
            )
            let preparedOwnership = PreparedContainerRootFS.Ownership(
                containerID: containerID,
                reservation: reservation,
                createdAt: createdAt
            )
            ownership = preparedOwnership
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(preparedOwnership).write(
                to: marker,
                options: [.atomic]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: marker.path
            )
            try Self.synchronizeFile(at: marker)

            let stagedRootFSURL = stagingDirectory.appendingPathComponent(
                "rootfs.ext4",
                isDirectory: false
            )
            var clone = try snapshot.clone(to: stagedRootFSURL.path)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stagedRootFSURL.path
            )
            if readOnly, !clone.options.contains("ro") {
                clone.options.append("ro")
            }
            try Self.synchronizeFile(at: stagedRootFSURL)
            try Self.synchronizeDirectory(at: stagingDirectory)
            try Task.checkCancellation()

            beforePublish?(stagingDirectory, bundleDirectory)
            try Task.checkCancellation()
            try Self.publishWithoutReplacing(
                stagingDirectory,
                at: bundleDirectory,
                containerID: containerID
            )
            published = true
            try Self.synchronizeDirectory(at: containersRoot)

            // `clone(to:)` names the staging path. The directory has moved as
            // one atomic unit, so hand Apple the corresponding final path.
            clone.source =
                bundleDirectory.appendingPathComponent(
                    "rootfs.ext4",
                    isDirectory: false
                ).path
            return PreparedContainerRootFS(
                filesystem: clone,
                bundleDirectory: bundleDirectory,
                ownership: preparedOwnership
            )
        } catch {
            if published,
                let ownership,
                PreparedContainerRootFS.ownership(at: bundleDirectory)
                    == ownership
            {
                try? FileManager.default.removeItem(at: bundleDirectory)
                try? Self.synchronizeDirectory(at: containersRoot)
            } else if !published {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
            throw error
        }
    }

    func ownedPreCreateBundle(
        containerID: String
    ) throws -> (directory: URL, ownership: PreparedContainerRootFS.Ownership)? {
        let containersRoot = appSupportURL.appendingPathComponent(
            "containers",
            isDirectory: true
        ).standardizedFileURL
        let bundleDirectory = containersRoot.appendingPathComponent(
            containerID,
            isDirectory: true
        ).standardizedFileURL
        guard bundleDirectory.deletingLastPathComponent() == containersRoot
        else {
            throw ContainerRootFSMaterializationError.unsafeContainerID(
                containerID
            )
        }
        guard
            let ownership = PreparedContainerRootFS.ownership(
                at: bundleDirectory
            )
        else {
            return nil
        }
        guard ownership.containerID == containerID else { return nil }
        return (bundleDirectory, ownership)
    }

    /// Opportunistically removes private staging bundles abandoned by a hard
    /// process crash before atomic publication. Only direct children bearing
    /// our exact UUID-shaped prefix, a current-format ownership marker older
    /// than the cutoff, and an inactive reservation are eligible. The marker
    /// is re-read after the actor hop so a concurrently changed directory is
    /// preserved. Fresh, active, foreign, and malformed entries are ignored.
    func recoverStalePrivateStagingBundles(
        reservationRegistry: ContainerImageLeaseReservationRegistry,
        staleAfter: TimeInterval = Self.staleStagingBundleAge,
        now: Date = Date(),
        maximumRecoveries: Int = Self.maximumStagingRecoveriesPerPass
    ) async -> Int {
        guard maximumRecoveries > 0 else { return 0 }
        let containersRoot = appSupportURL.appendingPathComponent(
            "containers",
            isDirectory: true
        ).standardizedFileURL
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: containersRoot,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]
            )
        else {
            return 0
        }
        let candidates: [(URL, PreparedContainerRootFS.Ownership)] =
            entries
            .compactMap { candidate in
                guard Self.isPrivateStagingBundle(candidate) else {
                    return nil
                }
                guard
                    let values = try? candidate.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                    ]),
                    values.isDirectory == true,
                    values.isSymbolicLink != true,
                    let ownership = PreparedContainerRootFS.ownership(
                        at: candidate
                    )
                else {
                    return nil
                }
                return (candidate.standardizedFileURL, ownership)
            }.sorted { lhs, rhs in
                if lhs.1.createdAt != rhs.1.createdAt {
                    return lhs.1.createdAt < rhs.1.createdAt
                }
                return lhs.0.lastPathComponent < rhs.0.lastPathComponent
            }

        let cutoff = now.addingTimeInterval(-max(0, staleAfter))
        var recovered = 0
        for (candidate, ownership) in candidates {
            guard recovered < maximumRecoveries else { break }
            guard ownership.createdAt <= cutoff else { break }
            guard
                !(await reservationRegistry.isReserved(
                    id: ownership.reservationID
                ))
            else {
                continue
            }
            // Revalidate the exact marker after awaiting actor state. A live
            // materializer with this reservation cannot become inactive and
            // later reuse the same UUID, so an unchanged inactive marker is an
            // abandoned attempt.
            guard
                PreparedContainerRootFS.ownership(at: candidate) == ownership
            else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: candidate)
                recovered += 1
            } catch {
                // A concurrent scavenger may have won. Leave all other
                // candidates eligible rather than failing container create.
                continue
            }
        }
        if recovered > 0 {
            try? Self.synchronizeDirectory(at: containersRoot)
        }
        return recovered
    }

    /// Removes only a valid Glass Dock marker for the exact stale attempt. The
    /// caller must first prove that Apple has no container with this ID and that
    /// the reservation token is no longer active.
    func recoverStaleOwnedPreCreateBundle(
        containerID: String,
        ownership expected: PreparedContainerRootFS.Ownership,
        olderThan cutoff: Date
    ) throws -> Bool {
        guard expected.createdAt <= cutoff else { return false }
        guard
            let current = try ownedPreCreateBundle(containerID: containerID),
            current.ownership == expected
        else {
            return false
        }
        try FileManager.default.removeItem(at: current.directory)
        return true
    }

    private static func createPrivateStagingBundle(
        in containersRoot: URL
    ) throws -> URL {
        for _ in 0..<10 {
            let directory = containersRoot.appendingPathComponent(
                "\(stagingBundlePrefix)\(UUID().uuidString)",
                isDirectory: true
            )
            if Darwin.mkdir(directory.path, 0o700) == 0 {
                return directory
            }
            let code = errno
            if code == EEXIST { continue }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        throw POSIXError(.EEXIST)
    }

    private static func isPrivateStagingBundle(_ candidate: URL) -> Bool {
        let name = candidate.lastPathComponent
        guard name.hasPrefix(stagingBundlePrefix) else { return false }
        let suffix = String(name.dropFirst(stagingBundlePrefix.count))
        return UUID(uuidString: suffix) != nil
    }

    private static func publishWithoutReplacing(
        _ stagingDirectory: URL,
        at bundleDirectory: URL,
        containerID: String
    ) throws {
        let result = renamex_np(
            stagingDirectory.path,
            bundleDirectory.path,
            UInt32(RENAME_EXCL)
        )
        guard result == 0 else {
            let code = errno
            if code == EEXIST || code == ENOTEMPTY {
                throw
                    ContainerRootFSMaterializationError
                    .containerBundleExists(containerID)
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private static func synchronizeFile(at url: URL) throws {
        try synchronize(at: url, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }

    private static func synchronizeDirectory(at url: URL) throws {
        try synchronize(
            at: url,
            flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
    }

    private static func synchronize(at url: URL, flags: Int32) throws {
        let descriptor: Int32
        while true {
            let opened = Darwin.open(url.path, flags)
            if opened >= 0 {
                descriptor = opened
                break
            }
            let code = errno
            if code == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }

        while Darwin.fsync(descriptor) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
