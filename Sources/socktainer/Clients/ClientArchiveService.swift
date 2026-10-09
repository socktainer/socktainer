import ContainerAPIClient
import ContainerResource
import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import SystemPackage
import Vapor

/// Extension to add convenience computed properties for EXT4.Inode
extension EXT4.Inode {
    /// Full 64-bit file size
    var size: Int64 {
        Int64(sizeLow) | (Int64(sizeHigh) << 32)
    }

    /// Full 32-bit user ID
    var fullUid: UInt32 {
        UInt32(uid) | (UInt32(uidHigh) << 16)
    }

    /// Full 32-bit group ID
    var fullGid: UInt32 {
        UInt32(gid) | (UInt32(gidHigh) << 16)
    }

    /// Check if this is a directory
    var isDirectory: Bool {
        (mode & 0xF000) == 0x4000
    }

    /// Check if this is a regular file
    var isRegularFile: Bool {
        (mode & 0xF000) == 0x8000
    }

    /// Check if this is a symbolic link
    var isSymlink: Bool {
        (mode & 0xF000) == 0xA000
    }

    /// Permission bits only (without file type)
    var permissions: UInt16 {
        mode & 0x0FFF
    }
}

/// Errors specific to archive operations
enum ClientArchiveError: Error, LocalizedError {
    case containerNotFound(id: String)
    case pathNotFound(path: String)
    case rootfsNotFound(id: String)
    case invalidPath(path: String)
    case notADirectory(path: String)
    case operationFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .containerNotFound(let id):
            return "Container not found: \(id)"
        case .pathNotFound(let path):
            return "Path not found in container: \(path)"
        case .rootfsNotFound(let id):
            return "Rootfs not found for container: \(id)"
        case .invalidPath(let path):
            return "Invalid path: \(path)"
        case .notADirectory(let path):
            return "Extraction point is not a directory: \(path)"
        case .operationFailed(let message):
            return "Archive operation failed: \(message)"
        }
    }
}

/// POSIX `st_mode` in Go's `os.FileMode` encoding, which is what the Docker API
/// carries: permission bits are shared, but Go keeps the file type in the high
/// bits rather than in `S_IFMT`.
func goFileMode(posixMode: UInt32) -> UInt32 {
    var mode = posixMode & 0o777
    switch posixMode & 0o170000 {
    case 0o040000: mode |= 1 << 31  // ModeDir
    case 0o120000: mode |= 1 << 27  // ModeSymlink
    case 0o020000: mode |= (1 << 26) | (1 << 21)  // ModeDevice | ModeCharDevice
    case 0o060000: mode |= 1 << 26  // ModeDevice
    case 0o010000: mode |= 1 << 25  // ModeNamedPipe
    case 0o140000: mode |= 1 << 24  // ModeSocket
    default: break  // regular files carry no type bit
    }
    if posixMode & 0o4000 != 0 { mode |= 1 << 23 }  // ModeSetuid
    if posixMode & 0o2000 != 0 { mode |= 1 << 22 }  // ModeSetgid
    if posixMode & 0o1000 != 0 { mode |= 1 << 20 }  // ModeSticky
    return mode
}

/// Go's RFC3339Nano in the daemon's own timezone, as Docker reports it. An ext4
/// inode holds whole seconds and Go omits a zero fraction, so only the offset
/// differs from RFC3339.
func dockerPathStatTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
    return formatter.string(from: date)
}

/// Subset of Apple Container's `runtime-configuration.json` (written at
/// container create time) containing the rootfs source reference.
private struct RuntimeConfiguration: Decodable {
    struct Filesystem: Decodable {
        let source: String
    }

    let containerRootFilesystem: Filesystem
}

/// File stat information for the X-Docker-Container-Path-Stat header
struct PathStat: Codable {
    let name: String
    let size: Int64
    let mode: UInt32
    let mtime: String
    let linkTarget: String

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case mode
        case mtime
        case linkTarget
    }
}

/// Protocol for archive operations on containers
protocol ClientArchiveProtocol: Sendable {
    /// Get the path to a container's rootfs
    func getRootfsPath(containerId: String) -> URL

    /// Read a file or directory from a container's filesystem and return as tar data
    func getArchive(container: ContainerSnapshot, path: String) async throws -> (tarData: Data, stat: PathStat)

    /// Stat a path without reading it, for callers that only need the header
    func statPath(container: ContainerSnapshot, path: String) async throws -> PathStat

    /// Extract a tar archive into a container's filesystem at the specified path
    func putArchive(container: ContainerSnapshot, path: String, tarPath: URL, noOverwriteDirNonDir: Bool) async throws

    /// Export the container's entire root filesystem as an uncompressed tar
    /// (docker export). The caller owns the returned file and deletes it when done.
    func exportRootfs(containerId: String) async throws -> URL
}

/// Service for performing archive operations on container filesystems
struct ClientArchiveService: ClientArchiveProtocol {
    private let appSupportPath: URL
    private let flushTimeout: Duration
    private let flushDeadline: @Sendable (Duration) async throws -> Void
    private let flushGuest: @Sendable (ContainerSnapshot) async throws -> Void
    private let flushBreaker: GuestFlushBreaker

    private static let log = Logger(label: "socktainer.archive")

    /// How long a read waits for the guest flush before it reads whatever is on disk.
    static let defaultFlushTimeout: Duration = .seconds(5)

    /// - Parameters:
    ///   - flushTimeout: upper bound on each flush; past it the read proceeds anyway.
    ///   - flushDeadline: waits out `flushTimeout` for one flush; the flush times out
    ///     when it returns. Defaults to `Task.sleep`; injectable so tests decide when a
    ///     flush times out instead of racing a wall-clock cap.
    ///   - flushGuest: writes a running guest's page cache back to its `rootfs.ext4`
    ///     before the image is read from the host. Defaults to running `sync` in the
    ///     guest; injectable so tests need no VM.
    ///   - flushBreaker: containers whose flush timed out and has not returned (see
    ///     `GuestFlushBreaker` for when that expires). A reference type, so copies of
    ///     this service share it; the server creates one service for its lifetime
    ///     (`configure.swift`), and each new service (each test) starts with an empty
    ///     breaker.
    init(
        appSupportPath: URL,
        flushTimeout: Duration = ClientArchiveService.defaultFlushTimeout,
        flushDeadline: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        flushGuest: @escaping @Sendable (ContainerSnapshot) async throws -> Void = ClientArchiveService.syncGuest,
        flushBreaker: GuestFlushBreaker = GuestFlushBreaker()
    ) {
        self.appSupportPath = appSupportPath
        self.flushTimeout = flushTimeout
        self.flushDeadline = flushDeadline
        self.flushGuest = flushGuest
        self.flushBreaker = flushBreaker
    }

    /// Get the path to a container's rootfs.ext4 file
    func getRootfsPath(containerId: String) -> URL {
        appSupportPath
            .appendingPathComponent("containers")
            .appendingPathComponent(containerId)
            .appendingPathComponent("rootfs.ext4")
    }

    /// Resolve the ext4 file backing a container's rootfs.
    ///
    /// Apple Container provisions `containers/{id}/rootfs.ext4` only at first
    /// start, so a created-but-never-started container has no rootfs file
    /// (its `containers/{id}` directory holds runtime config only). Until the
    /// container boots, its filesystem is the image's shared snapshot
    /// referenced by `runtime-configuration.json` — read-only by construction
    /// (every container of an image points at the same file), so reads can
    /// safely serve from it.
    ///
    /// A container that has ever booted always has a private rootfs.ext4
    /// (provisioned at start, persists after stop), so absence of the file
    /// means "never started" — unless the rootfs was removed out-of-band, in
    /// which case falling back to the image snapshot would silently serve
    /// stale image content. `startedDate` is the runtime's ground truth for
    /// "has booted" and gates the fallback.
    private func resolveRootfsPath(container: ContainerSnapshot) throws -> URL {
        let rootfsPath = getRootfsPath(containerId: container.id)
        guard !FileManager.default.fileExists(atPath: rootfsPath.path) else {
            return rootfsPath
        }

        guard container.startedDate == nil else {
            throw ClientArchiveError.rootfsNotFound(id: container.id)
        }

        let configURL =
            appSupportPath
            .appendingPathComponent("containers")
            .appendingPathComponent(container.id)
            .appendingPathComponent("runtime-configuration.json")
        guard
            let data = try? Data(contentsOf: configURL),
            let config = try? JSONDecoder().decode(RuntimeConfiguration.self, from: data),
            !config.containerRootFilesystem.source.isEmpty
        else {
            throw ClientArchiveError.rootfsNotFound(id: container.id)
        }

        let snapshotURL = URL(fileURLWithPath: config.containerRootFilesystem.source)
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            throw ClientArchiveError.rootfsNotFound(id: container.id)
        }
        return snapshotURL
    }

    /// Make recent guest writes visible to a host-side read of `rootfs.ext4`.
    ///
    /// The reads below parse the ext4 image from the host while the guest VM owns
    /// it. A file the guest wrote recently sits in the guest page cache until it is
    /// written back, so reading it straight away reports "not found" (for example a
    /// step's `$GITHUB_OUTPUT` file read back by `docker cp`). Only a running
    /// container has a live guest; stopped and never-started ones are read as-is.
    ///
    /// Best effort: a failed or stalled flush is logged and the read goes ahead with
    /// whatever is already on disk, which is what happened before the flush existed.
    ///
    /// A flush that times out is abandoned, not killed (see `boundedFlush`). To keep a
    /// client polling a wedged guest from piling up abandoned work, the timeout trips
    /// the container in `flushBreaker`: reads skip the flush and read as-is (the same
    /// outcome as a timeout) until that flush returns or the trip expires, after which
    /// one probe flush is tried. Reads that arrive concurrently before the first
    /// timeout each start their own flush; the breaker bounds sequential and polling
    /// clients.
    private func flushIfRunning(_ container: ContainerSnapshot) async {
        guard container.status == .running else { return }
        let breaker = flushBreaker
        guard let attempt = breaker.begin(containerId: container.id) else {
            Self.log.debug(
                "Skipping guest sync before archive read for \(container.id): an earlier sync timed out; reading rootfs as-is until it returns or the trip expires"
            )
            return
        }
        if attempt.isProbe {
            Self.log.debug("Probing guest sync before archive read for \(container.id) after an earlier timeout")
        }
        let flushGuest = flushGuest
        let outcome = await Self.boundedFlush(timeout: flushTimeout, sleep: flushDeadline) {
            // Runs inside the work `runBounded` waits on, so it also runs when this
            // flush returns long after the read gave up on it.
            defer { breaker.finish(attempt) }
            try await flushGuest(container)
        }
        switch outcome {
        case .flushed:
            break
        case .failed(let error):
            Self.log.debug("Guest sync before archive read failed for \(container.id): \(error)")
        case .timedOut:
            breaker.abandon(attempt)
            Self.log.warning(
                "Guest sync before archive read did not finish within \(flushTimeout) for \(container.id); reading rootfs as-is and skipping guest syncs for this container until it returns or the trip expires"
            )
        }
    }

    enum FlushOutcome: Sendable {
        case flushed
        case failed(any Error)
        case timedOut
    }

    /// Runs `flush`, returning once it finishes or `timeout` passes, whichever is first.
    ///
    /// The guest flush is an exec over XPC (`createProcess`, `start`, `wait`), and none
    /// of those awaits react to task cancellation, so a task-group race would still wait
    /// for a stuck exec after the deadline. `StartupHousekeeping.runBounded` runs the work
    /// in an unstructured task and resumes on whichever finishes first; a flush still
    /// running at the deadline is abandoned, not killed. `sleep` is the deadline's wait
    /// (see `runBounded`).
    static func boundedFlush(
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ flush: @escaping @Sendable () async throws -> Void
    ) async -> FlushOutcome {
        final class ErrorBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: (any Error)?
            var error: (any Error)? {
                get { lock.withLock { stored } }
                set { lock.withLock { stored = newValue } }
            }
        }
        let box = ErrorBox()
        let finished = await StartupHousekeeping.runBounded(timeout: timeout, sleep: sleep) {
            do {
                try await flush()
            } catch {
                box.error = error
            }
        }
        guard finished else { return .timedOut }
        if let error = box.error { return .failed(error) }
        return .flushed
    }

    struct GuestSyncExitError: Error, CustomStringConvertible {
        let status: Int32
        var description: String { "/bin/sync exited with status \(status)" }
    }

    /// Run `/bin/sync` as root in the guest, from `/` (the image's working directory
    /// may not exist). Throws if the exec cannot be created or started (for example
    /// an image without `/bin/sync`) or exits non-zero.
    static func syncGuest(container: ContainerSnapshot) async throws {
        var processConfig = container.configuration.initProcess
        processConfig.executable = "/bin/sync"
        processConfig.arguments = []
        processConfig.workingDirectory = "/"
        processConfig.terminal = false
        processConfig.user = .id(uid: 0, gid: 0)

        let process = try await ContainerClient().createProcess(
            containerId: container.id,
            processId: UUID().uuidString.lowercased(),
            configuration: processConfig,
            stdio: [nil, nil, nil]
        )
        try await process.start()
        let status = try await process.wait()
        guard status == 0 else { throw GuestSyncExitError(status: status) }
    }

    /// Read a file or directory from a container's filesystem and return as tar data
    /// This implementation reads only the requested path directly, avoiding full filesystem export.
    /// Stat a single path, reading the inode and nothing else.
    ///
    /// `getArchive` builds a tar of everything under the path before its caller
    /// discards it. For `/` that is the whole filesystem, which is why a HEAD
    /// against a large image took as long as reading it.
    func statPath(container: ContainerSnapshot, path: String) async throws -> PathStat {
        await flushIfRunning(container)
        let rootfsPath = try resolveRootfsPath(container: container)
        guard FileManager.default.fileExists(atPath: rootfsPath.path) else {
            throw ClientArchiveError.rootfsNotFound(id: container.id)
        }

        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
        guard reader.exists(FilePath(normalizedPath)) else {
            throw ClientArchiveError.pathNotFound(path: normalizedPath)
        }

        let (_, inode) = try reader.stat(FilePath(normalizedPath))
        return PathStat(
            name: (normalizedPath as NSString).lastPathComponent,
            size: inode.size,
            mode: goFileMode(posixMode: UInt32(inode.mode)),
            mtime: dockerPathStatTimestamp(Date(timeIntervalSince1970: TimeInterval(inode.mtime))),
            linkTarget: (inode.isSymlink ? readSymlinkTarget(reader: reader, path: normalizedPath) : nil) ?? ""
        )
    }

    func getArchive(container: ContainerSnapshot, path: String) async throws -> (tarData: Data, stat: PathStat) {
        await flushIfRunning(container)
        let rootfsPath = try resolveRootfsPath(container: container)

        guard FileManager.default.fileExists(atPath: rootfsPath.path) else {
            throw ClientArchiveError.rootfsNotFound(id: container.id)
        }

        // Normalize the path
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        // Open the ext4 filesystem
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))

        // Check if path exists and get stat. Like moby's lstat-based path
        // resolution, a final-component symlink is reported as the symlink
        // itself (linkTarget + symlink tar entry, dangling included), while
        // intermediate symlink components are followed.
        guard reader.exists(FilePath(normalizedPath)) || reader.exists(FilePath(normalizedPath), followSymlinks: false) else {
            throw ClientArchiveError.pathNotFound(path: normalizedPath)
        }

        let (_, inode) =
            try (try? reader.stat(FilePath(normalizedPath), followSymlinks: false))
            ?? reader.stat(FilePath(normalizedPath))

        // Create PathStat for the response header
        let pathStat = PathStat(
            name: (normalizedPath as NSString).lastPathComponent,
            size: inode.size,
            mode: goFileMode(posixMode: UInt32(inode.mode)),
            mtime: dockerPathStatTimestamp(Date(timeIntervalSince1970: TimeInterval(inode.mtime))),
            linkTarget: (inode.isSymlink ? readSymlinkTarget(reader: reader, path: normalizedPath) : nil) ?? ""
        )

        // Create temporary directory for tar creation
        let tempDir = FileManager.default.temporaryDirectory
        let sessionId = UUID().uuidString
        let stagingDir = tempDir.appendingPathComponent("\(sessionId)-staging")
        let tarPath = tempDir.appendingPathComponent("\(sessionId).tar")

        defer {
            try? FileManager.default.removeItem(at: stagingDir)
            try? FileManager.default.removeItem(at: tarPath)
        }

        let baseName = (normalizedPath as NSString).lastPathComponent

        if inode.isDirectory {
            // Directories: stage the subtree, then archive it. Entries are
            // `./`-prefixed — accepted by docker cp.
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

            // Extract the requested path to the staging directory
            try extractPathToDirectory(reader: reader, sourcePath: normalizedPath, destDir: stagingDir)

            // Create tar archive from the staging directory
            try ArchiveUtility.create(tarPath: tarPath, from: stagingDir)
        } else {
            // Single file or symlink: emit exactly one tar entry named after
            // the basename, matching moby's archivePath output (no `./`
            // directory entry). The directory-wrapped form breaks consumers
            // that take the first tar entry as the payload
            let writer = try ArchiveWriter(format: .paxRestricted, filter: .none, file: tarPath)
            let entry = WriteEntry(writer)
            entry.path = baseName
            entry.fileType = inode.isRegularFile ? .regular : .symbolicLink
            entry.permissions = inode.permissions
            entry.owner = inode.fullUid
            entry.group = inode.fullGid
            entry.modificationDate = Date(timeIntervalSince1970: TimeInterval(inode.mtime))
            if inode.isSymlink {
                entry.symlinkTarget = readSymlinkTarget(reader: reader, path: normalizedPath)
            }
            let data = inode.isRegularFile ? try reader.readFile(at: FilePath(normalizedPath)) : nil
            if let data {
                entry.size = Int64(data.count)
                try writer.writeEntry(entry: entry, data: data)
            } else {
                try writer.writeEntry(entry: entry, data: nil as UnsafeRawBufferPointer?)
            }
            try writer.finishEncoding()
        }

        // Read the tar data
        let tarData = try Data(contentsOf: tarPath)

        return (tarData: tarData, stat: pathStat)
    }

    /// Reading rootfs.ext4 while the guest VM writes to it is a volatile
    /// snapshot — the same guarantee moby gives when exporting a running
    /// container's mounted layer. The export runs detached because it is
    /// synchronous I/O that can take minutes for large filesystems.
    func exportRootfs(containerId: String) async throws -> URL {
        let rootfsPath = getRootfsPath(containerId: containerId)
        guard FileManager.default.fileExists(atPath: rootfsPath.path) else {
            throw ClientArchiveError.rootfsNotFound(id: containerId)
        }
        let tarPath = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).tar")
        let blockDevicePath = rootfsPath.path
        let archivePath = tarPath.path
        do {
            try await Task.detached(priority: .utility) {
                let reader = try EXT4.EXT4Reader(blockDevice: FilePath(blockDevicePath))
                try reader.export(archive: FilePath(archivePath))
            }.value
        } catch {
            try? FileManager.default.removeItem(at: tarPath)
            throw ClientArchiveError.operationFailed(message: "failed to read rootfs of \(containerId): \(error)")
        }
        return tarPath
    }

    /// Extract a tar archive into a container's filesystem at the specified path
    func putArchive(container: ContainerSnapshot, path: String, tarPath: URL, noOverwriteDirNonDir: Bool) async throws {
        // Normalize the destination path
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        // A running container's VM holds rootfs.ext4 open as its block device:
        // rewriting and swapping the file on the host is never seen by the guest
        // (and guest writes would diverge from the swapped file). Inject through
        // the live container instead.
        if container.status == .running {
            try await putArchiveViaCopyIn(
                container: container,
                destinationPath: normalizedPath,
                tarPath: tarPath,
                noOverwriteDirNonDir: noOverwriteDirNonDir
            )
            return
        }

        let rootfsPath = getRootfsPath(containerId: container.id)

        guard FileManager.default.fileExists(atPath: rootfsPath.path) else {
            // Never booted: hold the files until the runtime builds the
            // filesystem, rather than refuse a copy Docker would accept.
            if container.startedDate == nil {
                try await stagePreStartInjection(
                    container: container, destinationPath: normalizedPath, tarPath: tarPath)
                return
            }
            // Booted before and the rootfs is gone: staging would quietly
            // resurrect the container carrying only these files.
            throw ClientArchiveError.rootfsNotFound(id: container.id)
        }

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
        try validateArchiveEntries(
            reader: reader,
            tarPath: tarPath,
            destinationPath: normalizedPath,
            noOverwriteDirNonDir: noOverwriteDirNonDir
        )

        try await putArchiveFallback(
            rootfsPath: rootfsPath,
            destinationPath: normalizedPath,
            inputTarPath: tarPath
        )
    }

    /// Hold an archive uploaded before the container was ever started.
    ///
    /// Only regular files: a directory would need a whole-directory mount,
    /// which hides what the image put there, and a symlink has no mount that
    /// reproduces it. Both are refused while the copy can still be retried
    /// after start.
    private func stagePreStartInjection(
        container: ContainerSnapshot, destinationPath: String, tarPath: URL
    ) async throws {
        let plan = try parseArchiveEntries(tarPath: tarPath, destinationPath: destinationPath)
        for entry in plan {
            if case .symlink = entry.kind {
                throw ClientArchiveError.operationFailed(
                    message: "cannot copy a symlink into \(container.id) before it starts")
            }
            if case .directory = entry.kind {
                throw ClientArchiveError.operationFailed(
                    message: "cannot copy a directory into \(container.id) before it starts")
            }
        }

        // An empty tar carries nothing to stage, and `ArchiveReader.extractContents`
        // rejects an archive with no entries, so extracting it would turn a no-op
        // Docker answers with 200 into a 500. buildx's docker-container driver
        // sends exactly this when it has no buildkitd.toml to inject. Mirrors the
        // empty-plan return in the running-container path.
        guard !plan.isEmpty else { return }

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prestart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try ArchiveUtility.extract(tarPath: tarPath, to: stagingDir)

        for entry in plan {
            guard case .file = entry.kind else { continue }
            let extracted = stagingDir.appendingPathComponent(entry.relativePath)
            guard FileManager.default.fileExists(atPath: extracted.path) else {
                throw ClientArchiveError.operationFailed(
                    message: "archive entry missing after extraction: \(entry.relativePath)")
            }
            try await PreStartInjectionStore.shared.stage(
                containerId: container.id, guestPath: entry.guestPath,
                source: extracted, mode: entry.mode)
        }
    }

    /// One parsed entry of the uploaded archive.
    private struct ArchiveEntryPlan {
        enum Kind {
            case directory
            case file
            case symlink(target: String)
        }
        let relativePath: String
        let guestPath: String
        let kind: Kind
        let mode: UInt32
    }

    /// Inject the archive into a RUNNING container.
    ///
    /// Docker semantics require extracting *into* the destination without
    /// disturbing what already exists (e.g. a tar entry `tmp/foo` must not
    /// change the ownership/mode/sticky bit of an existing `/tmp`). So instead
    /// of pushing whole directories through copyIn (whose in-guest extraction
    /// applies archived directory metadata over existing directories), this:
    ///  1. runs ONE `/bin/sh` exec in the guest that validates the destination
    ///     (404/400/conflict semantics that copyIn cannot express) and creates
    ///     missing directories and symlinks (`mkdir` skips existing dirs), then
    ///  2. streams each regular file individually over vsock via the daemon's
    ///     copyIn API with the mode recorded in the tar.
    private func putArchiveViaCopyIn(
        container: ContainerSnapshot,
        destinationPath: String,
        tarPath: URL,
        noOverwriteDirNonDir: Bool
    ) async throws {
        let plan = try parseArchiveEntries(tarPath: tarPath, destinationPath: destinationPath)

        try await prepareGuestForCopy(
            container: container,
            destinationPath: destinationPath,
            entries: plan,
            noOverwriteDirNonDir: noOverwriteDirNonDir
        )

        let files = plan.filter {
            if case .file = $0.kind { return true }
            return false
        }
        guard !files.isEmpty else { return }

        // Unpack the uploaded tar to a staging directory for the file contents
        // (modes are taken from the tar entries, not the staged files).
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("put-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        try ArchiveUtility.extract(tarPath: tarPath, to: stagingDir)

        let client = ContainerClient()
        for file in files {
            let stagedURL = stagingDir.appendingPathComponent(file.relativePath)
            guard FileManager.default.fileExists(atPath: stagedURL.path) else {
                throw ClientArchiveError.operationFailed(message: "archive entry missing after extraction: \(file.relativePath)")
            }
            do {
                try await client.copyIn(
                    id: container.id,
                    source: stagedURL.path,
                    destination: file.guestPath,
                    mode: file.mode
                )
            } catch {
                throw ClientArchiveError.operationFailed(
                    message: "Failed to copy \(file.relativePath) into running container: \(error.localizedDescription)")
            }
        }
    }

    /// Parse the uploaded tar into a copy plan.
    private func parseArchiveEntries(tarPath: URL, destinationPath: String) throws -> [ArchiveEntryPlan] {
        let archiveReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: tarPath
        )

        var plan: [ArchiveEntryPlan] = []
        for (entry, _) in archiveReader.makeStreamingIterator() {
            guard let entryPath = entry.path,
                let guestPath = ArchiveUtility.destinationPath(for: entryPath, under: destinationPath),
                guestPath != destinationPath
            else {
                continue
            }

            var relativePath = entryPath
            if relativePath.hasPrefix("./") {
                relativePath = String(relativePath.dropFirst(2))
            }

            let mode = UInt32(entry.permissions) & 0o7777
            switch entry.fileType {
            case .directory:
                plan.append(.init(relativePath: relativePath, guestPath: guestPath, kind: .directory, mode: mode))
            case .regular:
                plan.append(.init(relativePath: relativePath, guestPath: guestPath, kind: .file, mode: mode))
            case .symbolicLink:
                guard let target = entry.symlinkTarget else { continue }
                plan.append(.init(relativePath: relativePath, guestPath: guestPath, kind: .symlink(target: target), mode: mode))
            default:
                throw ClientArchiveError.operationFailed(
                    message: "unsupported archive entry type for copy into a running container: \(relativePath)")
            }
        }
        return plan
    }

    /// Run Docker's PUT-archive validation inside the running guest and create
    /// the directory/symlink structure for the incoming archive: destination
    /// must exist (404) and be a directory (400), optional per-entry
    /// noOverwriteDirNonDir conflict checks, `mkdir` for missing directories
    /// (existing ones are left untouched), and `ln -sfn` for symlinks.
    private func prepareGuestForCopy(
        container: ContainerSnapshot,
        destinationPath: String,
        entries: [ArchiveEntryPlan],
        noOverwriteDirNonDir: Bool
    ) async throws {
        let script = buildPreparationScript(
            entries: entries,
            noOverwriteDirNonDir: noOverwriteDirNonDir
        )

        var processConfig = container.configuration.initProcess
        processConfig.executable = "/bin/sh"
        processConfig.arguments = ["-c", script, "sh", destinationPath]
        processConfig.terminal = false
        // Validate as root so restrictive permissions on parent directories
        // cannot mask the existence checks.
        processConfig.user = .id(uid: 0, gid: 0)

        guard let pipes = StdioPipes.make([.stderr]) else {
            throw ClientArchiveError.operationFailed(message: "Failed to create stderr pipe")
        }

        let process: ClientProcess
        do {
            process = try await ContainerClient().createProcess(
                containerId: container.id,
                processId: UUID().uuidString.lowercased(),
                configuration: processConfig,
                stdio: pipes.stdioArray
            )
        } catch {
            pipes.closeAll()
            throw ClientArchiveError.operationFailed(message: "Failed to exec into running container: \(error.localizedDescription)")
        }
        do {
            try await process.start()
        } catch {
            pipes.closeAfterHandoff()
            throw ClientArchiveError.operationFailed(message: "Failed to exec into running container: \(error.localizedDescription)")
        }

        // Drain stderr concurrently (capped at 16 KiB) while waiting.
        // collectOutput() is not used here because it reads unboundedly via
        // readDataToEndOfFile(); this capped reader prevents runaway memory growth.
        let stderrReader = pipes.stderr!.read
        let stderrTask = Task.detached { () -> Data in
            defer { try? stderrReader.close() }
            var collected = Data()
            while let chunk = try? stderrReader.read(upToCount: 4096), !chunk.isEmpty {
                if collected.count < 16 * 1024 {
                    collected.append(chunk)
                }
            }
            return collected
        }

        let exitCode: Int32
        do {
            exitCode = try await process.wait()
        } catch {
            // Concurrent close(2) + read(2) on the same fd is unsafe (NSException risk).
            // Rethrow immediately; stderrTask exits naturally when the process terminates
            // and Apple closes the write end.
            throw ClientArchiveError.operationFailed(message: "Failed waiting for validation in running container: \(error.localizedDescription)")
        }

        let stderrText =
            String(data: await stderrTask.value, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch exitCode {
        case 0:
            return
        case 40:
            throw ClientArchiveError.pathNotFound(path: destinationPath)
        case 41:
            throw ClientArchiveError.notADirectory(path: destinationPath)
        default:
            let detail = stderrText.isEmpty ? "" : ": \(stderrText)"
            throw ClientArchiveError.operationFailed(message: "Validation in running container failed (exit \(exitCode))\(detail)")
        }
    }

    /// Build the validation/preparation shell script run inside the guest.
    /// Only `sh`, `mkdir`, `ln` and `test` are required. Existing directories
    /// are never modified, mirroring how tar treats implicit parents.
    private func buildPreparationScript(
        entries: [ArchiveEntryPlan],
        noOverwriteDirNonDir: Bool
    ) -> String {
        var lines = [
            "set -u",
            "dest=\"$1\"",
            "if [ ! -e \"$dest\" ]; then echo \"destination does not exist: $dest\" >&2; exit 40; fi",
            "if [ ! -d \"$dest\" ]; then echo \"extraction point is not a directory: $dest\" >&2; exit 41; fi",
        ]

        if noOverwriteDirNonDir {
            for entry in entries {
                let quoted = shellSingleQuoted(entry.guestPath)
                if case .directory = entry.kind {
                    lines.append("if [ -e \(quoted) ] && [ ! -d \(quoted) ]; then echo \"refusing to overwrite non-directory with directory\" >&2; exit 43; fi")
                } else {
                    lines.append("if [ -d \(quoted) ]; then echo \"refusing to overwrite directory with non-directory\" >&2; exit 43; fi")
                }
            }
        }

        // Explicit directory entries: create missing ones with the archived
        // mode (parents first); never touch directories that already exist.
        let directories =
            entries
            .compactMap { entry -> (path: String, mode: UInt32)? in
                guard case .directory = entry.kind else { return nil }
                return (entry.guestPath, entry.mode)
            }
            .sorted { $0.path.count < $1.path.count }
        for directory in directories {
            let quoted = shellSingleQuoted(directory.path)
            let parent = shellSingleQuoted((directory.path as NSString).deletingLastPathComponent)
            let octal = String(directory.mode, radix: 8)
            lines.append(
                "if [ ! -d \(quoted) ]; then mkdir -p \(parent) && mkdir -m \(octal) \(quoted) || { echo \"failed to create directory \(directory.path)\" >&2; exit 44; }; fi")
        }

        // Implicit parents of file/symlink entries (mkdir -p is a no-op on
        // existing directories).
        var parents = Set<String>()
        for entry in entries {
            if case .directory = entry.kind { continue }
            let parent = (entry.guestPath as NSString).deletingLastPathComponent
            if !parent.isEmpty, parent != "/" {
                parents.insert(parent)
            }
        }
        for parent in parents.sorted() {
            lines.append("mkdir -p \(shellSingleQuoted(parent)) || { echo \"failed to create parent directory \(parent)\" >&2; exit 44; }")
        }

        for entry in entries {
            guard case .symlink(let target) = entry.kind else { continue }
            lines.append(
                "ln -sfn \(shellSingleQuoted(target)) \(shellSingleQuoted(entry.guestPath)) || { echo \"failed to create symlink \(entry.guestPath)\" >&2; exit 45; }")
        }

        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Fallback PUT using full read-modify-write approach
    private func putArchiveFallback(
        rootfsPath: URL,
        destinationPath: String,
        inputTarPath: URL
    ) async throws {
        // Create temporary files for the operation
        let tempDir = FileManager.default.temporaryDirectory
        let sessionId = UUID().uuidString
        let exportedTarPath = tempDir.appendingPathComponent("\(sessionId)-export.tar")
        let newRootfsPath = tempDir.appendingPathComponent("\(sessionId)-rootfs.ext4")

        defer {
            try? FileManager.default.removeItem(at: exportedTarPath)
            try? FileManager.default.removeItem(at: newRootfsPath)
        }

        // Step 1: Export existing filesystem to tar
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
        try reader.export(archive: FilePath(exportedTarPath.path))

        // Step 2: Get the size of the existing rootfs to create a new one of similar size
        let rootfsAttributes = try FileManager.default.attributesOfItem(atPath: rootfsPath.path)
        let rootfsSize = (rootfsAttributes[.size] as? UInt64) ?? (2 * 1024 * 1024 * 1024)  // Default 2GB

        // Step 3: Create a new ext4 formatter
        // Use a minimum size that can accommodate the filesystem
        let minSize = max(rootfsSize, 256 * 1024)  // At least 256KB
        let formatter = try EXT4.Formatter(
            FilePath(newRootfsPath.path),
            blockSize: 4096,
            minDiskSize: minSize
        )

        // Step 4: Unpack the existing filesystem
        let existingReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: exportedTarPath
        )
        try await formatter.unpack(reader: existingReader)

        // Step 5: Unpack the new tar at the specified destination path
        try ArchiveUtility.unpack(
            tarPath: inputTarPath,
            to: formatter,
            destinationPath: destinationPath
        )

        // Step 6: Finalize the new filesystem
        try formatter.close()

        // Step 7: Atomically replace the old rootfs with the new one
        let backupPath = rootfsPath.appendingPathExtension("backup")
        try? FileManager.default.removeItem(at: backupPath)

        // Move old rootfs to backup
        try FileManager.default.moveItem(at: rootfsPath, to: backupPath)

        do {
            // Move new rootfs into place
            try FileManager.default.moveItem(at: newRootfsPath, to: rootfsPath)
            // Remove backup on success
            try? FileManager.default.removeItem(at: backupPath)
        } catch {
            // Restore backup on failure
            try? FileManager.default.moveItem(at: backupPath, to: rootfsPath)
            throw ClientArchiveError.operationFailed(message: "Failed to replace rootfs: \(error.localizedDescription)")
        }
    }

    /// Read a symlink's target.
    ///
    /// EXT4.EXT4Reader has no public symlink API — `readFile(followSymlinks:
    /// false)` rejects symlink inodes with `notAFile`, and `followSymlinks:
    /// true` returns the *target file's* content. Fast symlinks (target < 60
    /// bytes, the overwhelming majority in practice) store the target inline
    /// in the inode block field, which is public; slow symlinks (>= 60 bytes)
    /// are not readable through the public API and report nil.
    private func readSymlinkTarget(reader: EXT4.EXT4Reader, path: String) -> String? {
        guard
            let inode = try? reader.stat(FilePath(path), followSymlinks: false).inode,
            inode.isSymlink
        else {
            return nil
        }
        let targetLength = inode.size
        guard targetLength > 0, targetLength < 60 else {
            return nil
        }
        let blockBytes = Mirror(reflecting: inode.block).children.map { $0.value as! UInt8 }
        return String(bytes: blockBytes.prefix(Int(targetLength)), encoding: .utf8)
    }

    private func validateArchiveEntries(
        reader: EXT4.EXT4Reader,
        tarPath: URL,
        destinationPath: String,
        noOverwriteDirNonDir: Bool
    ) throws {
        let archiveReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: tarPath
        )

        for (entry, _) in archiveReader.makeStreamingIterator() {
            guard let fullPath = ArchiveUtility.destinationPath(for: entry.path, under: destinationPath) else {
                continue
            }

            guard noOverwriteDirNonDir, reader.exists(FilePath(fullPath)) else {
                continue
            }

            let (_, inode) = try reader.stat(FilePath(fullPath))
            let existingIsDirectory = inode.isDirectory
            let incomingIsDirectory = entry.fileType == .directory

            if existingIsDirectory != incomingIsDirectory {
                throw ClientArchiveError.operationFailed(
                    message: "Refusing to overwrite \(existingIsDirectory ? "directory" : "non-directory") at \(fullPath)"
                )
            }
        }
    }

    /// Extract a path from the ext4 filesystem to a local directory.
    /// Symlinks are reported as symlinks (non-following stat, matching moby's
    /// lstat semantics) — recursive children are only listed for real
    /// directories, never followed through symlinks.
    private func extractPathToDirectory(reader: EXT4.EXT4Reader, sourcePath: String, destDir: URL) throws {
        let (_, inode) =
            try (try? reader.stat(FilePath(sourcePath), followSymlinks: false))
            ?? reader.stat(FilePath(sourcePath))
        let baseName = sourcePath == "/" ? nil : (sourcePath as NSString).lastPathComponent

        if inode.isDirectory {
            let dirDest: URL
            if let baseName {
                dirDest = destDir.appendingPathComponent(baseName)
                try FileManager.default.createDirectory(at: dirDest, withIntermediateDirectories: true)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: inode.permissions)],
                    ofItemAtPath: dirDest.path
                )
            } else {
                dirDest = destDir
            }

            // Recursively extract contents
            let entries = try reader.listDirectory(FilePath(sourcePath))
            for entry in entries {
                let childPath = sourcePath == "/" ? "/\(entry)" : "\(sourcePath)/\(entry)"
                try extractPathToDirectory(reader: reader, sourcePath: childPath, destDir: dirDest)
            }
        } else if inode.isRegularFile {
            // Read file contents
            let fileData = try reader.readFile(at: FilePath(sourcePath))
            guard let baseName else {
                throw ClientArchiveError.invalidPath(path: sourcePath)
            }
            let fileDest = destDir.appendingPathComponent(baseName)

            // Write file
            try fileData.write(to: fileDest)

            // Set permissions and modification time
            let mtimeDate = Date(timeIntervalSince1970: TimeInterval(inode.mtime))
            try FileManager.default.setAttributes(
                [
                    .posixPermissions: NSNumber(value: inode.permissions),
                    .modificationDate: mtimeDate,
                ],
                ofItemAtPath: fileDest.path
            )
        } else if inode.isSymlink {
            // Read symlink target
            if let target = readSymlinkTarget(reader: reader, path: sourcePath) {
                guard let baseName else {
                    throw ClientArchiveError.invalidPath(path: sourcePath)
                }
                let linkDest = destDir.appendingPathComponent(baseName)
                try FileManager.default.createSymbolicLink(atPath: linkDest.path, withDestinationPath: target)
            }
        }
        // Skip other file types (devices, fifos, sockets)
    }

}

/// Per-container circuit breaker for the guest flush before archive reads.
///
/// A container trips when a flush times out and is abandoned. While it is tripped,
/// reads skip the flush and read rootfs as-is, so a client polling a wedged guest
/// does not start one abandoned flush per read.
///
/// A trip does not last forever: the XPC call behind an abandoned flush may never
/// return, and a container restarted with the same id would otherwise stay tripped
/// (and read stale data) for the life of the server. `reArmInterval` after the trip
/// was last renewed, `begin` grants one probe flush and renews the trip, so other
/// reads keep skipping while the probe runs. A probe that times out trips the
/// container again; one that returns untrips it. Abandoned work is therefore bounded
/// to about one flush per interval per container.
///
/// Each flush is an `Attempt`. The flush work calls `finish` when it returns; the read
/// calls `abandon` after it timed out. Both run under one lock, and `abandon` does
/// nothing for an attempt that already finished, so a flush that returns right at the
/// deadline cannot leave the container tripped. An attempt that returns without having
/// been abandoned proves the guest answers and clears the trip, including attempts
/// abandoned earlier that may never return. An abandoned attempt that returns late
/// only counts for the trip it was abandoned into: it untrips the container once no
/// other abandoned attempt of that trip is still out, and does nothing once that trip
/// has ended (a later trip is about a later timeout it says nothing about).
///
/// Limit: an entry lives until its trip ends, so a container removed while tripped
/// leaves one small entry behind (reused if a container with the same id is created
/// later). Only containers whose flush timed out get one, so the map is bounded by
/// the wedged containers the server has seen.
final class GuestFlushBreaker: @unchecked Sendable {
    /// How long a trip lasts before one probe flush is allowed.
    static let defaultReArmInterval: Duration = .seconds(60)

    final class Attempt: @unchecked Sendable {
        let containerId: String
        /// Whether this attempt was granted while the container was tripped.
        let isProbe: Bool
        // Guarded by the owning breaker's lock.
        fileprivate var finished = false
        /// Set by `abandon`; the attempt then sits in that trip's `pending`.
        fileprivate var abandoned = false

        fileprivate init(containerId: String, isProbe: Bool) {
            self.containerId = containerId
            self.isProbe = isProbe
        }
    }

    private struct Trip {
        /// Abandoned attempts that have not returned.
        var pending: Set<ObjectIdentifier>
        /// The last abandon, or the last probe granted.
        var renewedAt: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private let reArmInterval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var trips: [String: Trip] = [:]

    /// - Parameters:
    ///   - reArmInterval: how long after the last abandoned (or probe) flush a tripped
    ///     container gets one new flush attempt.
    ///   - now: the clock; injectable so tests can expire a trip without waiting.
    init(
        reArmInterval: Duration = GuestFlushBreaker.defaultReArmInterval,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.reArmInterval = reArmInterval
        self.now = now
    }

    /// Whether reads of `containerId` currently skip the flush: an abandoned flush
    /// has not returned and the trip has not expired yet.
    func isTripped(containerId: String) -> Bool {
        lock.withLock {
            guard let trip = trips[containerId] else { return false }
            return now() - trip.renewedAt < reArmInterval
        }
    }

    /// Starts a flush attempt for `containerId`, or returns `nil` if the container is
    /// tripped and the read should skip the flush. Once a trip has expired, the first
    /// caller gets a probe attempt and renews the trip, so concurrent callers skip.
    func begin(containerId: String) -> Attempt? {
        lock.withLock {
            guard var trip = trips[containerId] else {
                return Attempt(containerId: containerId, isProbe: false)
            }
            let instant = now()
            guard instant - trip.renewedAt >= reArmInterval else { return nil }
            trip.renewedAt = instant
            trips[containerId] = trip
            return Attempt(containerId: containerId, isProbe: true)
        }
    }

    /// The flush returned (in time or not).
    func finish(_ attempt: Attempt) {
        lock.withLock {
            attempt.finished = true
            let id = attempt.containerId
            guard var trip = trips[id] else { return }
            guard attempt.abandoned else {
                // Returned before the read gave up on it: the guest answers.
                trips[id] = nil
                return
            }
            // Abandoned: it only belongs to the trip whose `pending` holds it. If that
            // trip already ended, the current one is a later, unrelated timeout.
            guard trip.pending.remove(ObjectIdentifier(attempt)) != nil else { return }
            trips[id] = trip.pending.isEmpty ? nil : trip
        }
    }

    /// The read stopped waiting for the flush. Trips its container (renewing the trip)
    /// unless the flush already returned. Returns whether it tripped.
    @discardableResult
    func abandon(_ attempt: Attempt) -> Bool {
        lock.withLock {
            guard !attempt.finished else { return false }
            attempt.abandoned = true
            let id = attempt.containerId
            var trip = trips[id] ?? Trip(pending: [], renewedAt: now())
            trip.pending.insert(ObjectIdentifier(attempt))
            trip.renewedAt = now()
            trips[id] = trip
            return true
        }
    }
}
