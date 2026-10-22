import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import Logging
import SystemPackage

enum ArchiveUtilityError: Error {
    case invalidPath
    case archiveCreationFailed(String)
    case archiveReadFailed(String)
    case archiveWriteFailed(String)
    case entryReadFailed(String)
    case rejectedArchiveEntries([String])
}

struct ArchiveUtility {

    static func extract(tarPath: URL, to destination: URL, logger: Logger? = nil) throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: tarPath.path) else {
            throw ArchiveUtilityError.invalidPath
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let archiveReader: ArchiveReader
        do {
            archiveReader = try ArchiveReader(file: tarPath)
        } catch {
            throw ArchiveUtilityError.archiveCreationFailed(error.localizedDescription)
        }

        do {
            let rejectedPaths = try extractEntries(from: archiveReader, to: destination, logger: logger)
            if !rejectedPaths.isEmpty {
                throw ArchiveUtilityError.rejectedArchiveEntries(rejectedPaths)
            }
        } catch {
            if let error = error as? ArchiveUtilityError {
                throw error
            }
            throw ArchiveUtilityError.archiveReadFailed(error.localizedDescription)
        }
    }

    /// Extracts every entry from `reader` into `destination`, entry by entry via
    /// the archive's public streaming iterator.
    ///
    /// `ArchiveReader.extractContents(to:)` (from the vendored Containerization
    /// framework) creates regular files via `open(O_CREAT | O_EXCL | O_WRONLY, entry.permissions)`,
    /// using the entry's own recorded mode as the create mode. On macOS that
    /// fails with EACCES for any entry whose mode has no owner-write bit —
    /// e.g. read-only vendored/test binaries such as kubebuilder's envtest
    /// `etcd`/`kube-apiserver`, which real build contexts do contain — because
    /// the create-for-write and the final (read-only) permission bits can't
    /// both be satisfied by that one syscall. This creates files with a
    /// writable mode, writes their content, then `chmod`s to the entry's real
    /// mode afterward, so such entries extract instead of aborting the whole
    /// build.
    private static func extractEntries(from reader: ArchiveReader, to destination: URL, logger: Logger?) throws -> [String] {
        let fileManager = FileManager.default
        let destinationPath = destination.standardizedFileURL.path
        var rejectedPaths: [String] = []
        // Entry types this extractor has no support for (hard links, FIFOs, etc.) — these
        // are ordinary, benign tar features a real build context can legitimately contain,
        // unlike `rejectedPaths` (path traversal / symlink-planting), so they're only
        // logged, not treated as a reason to fail the whole extraction.
        var unsupportedPaths: [String] = []
        var foundEntry = false
        // Applied only after every entry is processed (see below the loop) — a directory's
        // recorded mode can be restrictive (e.g. read+execute only), and tar conventionally
        // lists a directory before its own contents, so applying it immediately could block
        // creating that directory's later children.
        var pendingDirectoryPermissions: [(path: String, mode: mode_t)] = []
        // Allocated once and reused for every regular-file entry's copy loop, instead of a
        // fresh 128 KiB zero-filled array per entry — a real archive can contain thousands
        // of small files.
        var copyBuffer = [UInt8](repeating: 0, count: 128 * 1024)

        for (entry, dataReader) in reader.makeStreamingIterator() {
            foundEntry = true
            guard let rawPath = entry.path else {
                unsupportedPaths.append("<unnamed entry>")
                continue
            }

            guard let fullPath = safeDestination(for: rawPath, under: destination, destinationPath: destinationPath) else {
                rejectedPaths.append(rawPath)
                continue
            }
            // `open(..., O_NOFOLLOW)` below only refuses a symlink at the FINAL path
            // component — a malicious archive can still plant a symlink entry (e.g.
            // `evil -> /etc`) and a later entry whose path runs *through* it
            // (`evil/cron.d/x`), since normal path resolution transparently follows a
            // symlink in an intermediate component. Reject those before touching the
            // filesystem at all, rather than relying on the final-component check alone.
            guard hasSafeAncestors(of: fullPath, under: destination) else {
                rejectedPaths.append(rawPath)
                continue
            }

            // The extraction root itself (fullPath == destination, from a "."/"./" entry per
            // `safeDestination`) may only ever be an ordinary directory entry — its own
            // pendingDirectoryPermissions handling further down applies just to that case.
            // Any OTHER entry type resolving directly to the destination (a regular file, a
            // symlink, or — the case this guards against — a hard link, which would `removeItem`
            // and then re-link the extraction root itself) is rejected outright rather than
            // processed, matching how every other unsafe entry shape here is handled.
            if fullPath.standardizedFileURL.path == destinationPath, entry.hardlink != nil || entry.fileType != .directory {
                rejectedPaths.append(rawPath)
                continue
            }

            // A hard-link entry carries a populated `hardlink` (the linked-to path,
            // archive-root-relative like the entry's own `path`, not entry-directory-relative
            // like a symlink target) regardless of what `fileType` itself reports for it
            // (confirmed empirically: this framework's reader surfaces a hard-link entry's
            // `fileType` as `.unknown`, landing it in the `default:` case below — NOT
            // `.regular`, despite that being this project's own EXT4 exporter's convention for
            // entries it constructs itself). Its data stream is empty — falling through to
            // `default:`'s "unsupported, skip" handling would silently produce no file at all
            // instead of linking to the earlier entry's real content.
            if let hardlinkTarget = entry.hardlink {
                guard let linkSource = safeDestination(for: hardlinkTarget, under: destination, destinationPath: destinationPath),
                    hasSafeAncestors(of: linkSource, under: destination)
                else {
                    rejectedPaths.append(rawPath)
                    continue
                }
                try fileManager.createDirectory(at: fullPath.deletingLastPathComponent(), withIntermediateDirectories: true)
                // "Last entry wins", matching `.regular`/`.directory`/`.symbolicLink`.
                try? fileManager.removeItem(at: fullPath)
                guard link(linkSource.path, fullPath.path) == 0 else {
                    // ENOENT (the archive references a hard-link target that hasn't been
                    // extracted, e.g. malformed ordering) is an unsupported/malformed entry,
                    // not a host-side failure — anything else still deserves a hard failure.
                    guard errno == ENOENT else {
                        throw ArchiveUtilityError.archiveWriteFailed("\(rawPath): link failed (errno \(errno))")
                    }
                    rejectedPaths.append(rawPath)
                    continue
                }
                continue
            }

            switch entry.fileType {
            case .directory:
                // "Last entry wins", matching the `.regular` case below: a prior entry may
                // have written a non-directory at this same path (e.g. a symlink or file
                // entry reusing the path before a later, corrected directory entry) —
                // `createDirectory` fails outright if something non-directory already
                // occupies the path, so clear it first the same way `.regular` does.
                // `lstat` (not `fileManager.fileExists(atPath:isDirectory:)`, which follows
                // symlinks) — a symlink at this exact path must be removed even when it
                // happens to resolve to an existing directory, or `createDirectory` below
                // would silently no-op and leave the symlink in place instead of a real
                // directory at `fullPath` itself.
                var linkInfo = stat()
                if lstat(fullPath.path, &linkInfo) == 0, (linkInfo.st_mode & S_IFMT) != S_IFDIR {
                    try? fileManager.removeItem(at: fullPath)
                }
                try fileManager.createDirectory(at: fullPath, withIntermediateDirectories: true)
                // Skip the extraction root itself (a `.`/`./` entry, per `safeDestination`,
                // resolves to `destination` verbatim) — the caller created `destination` with
                // its own intended permissions before extraction ever started, and a tar
                // entry's recorded mode for the archive's own top-level directory (which can be
                // arbitrarily restrictive) has no business overriding that.
                if fullPath.standardizedFileURL.path != destinationPath {
                    pendingDirectoryPermissions.append((fullPath.path, mode_t(entry.permissions & 0o777)))
                }
            case .regular:
                try fileManager.createDirectory(at: fullPath.deletingLastPathComponent(), withIntermediateDirectories: true)
                // "Last entry wins", matching the framework's own extraction semantics.
                try? fileManager.removeItem(at: fullPath)
                // O_EXCL | O_NOFOLLOW (matching the framework's own extraction code) closes a
                // TOC-TOU/symlink-planting attack: a malicious archive can't plant a symlink
                // entry, then a same-path regular-file entry, to make this write follow the
                // symlink outside `destination` (e.g. via `docker load`/`import` of an
                // untrusted tarball) — if the prior `removeItem` didn't actually clear the
                // path, this fails closed instead of writing through whatever's still there.
                // The create mode is writable regardless of the entry's own recorded mode
                // (fixed via `fchmod` after writing) — seeding the real, possibly read-only,
                // mode directly into O_CREAT fails with EACCES on macOS.
                let fd = open(fullPath.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
                guard fd >= 0 else {
                    // EEXIST (the prior `removeItem` didn't actually clear the path — the
                    // TOC-TOU case this guards) and ELOOP (a symlink at the final
                    // component) both mean the archive itself is malformed/hostile at this
                    // entry; anything else (ENOSPC, EMFILE, a real EACCES on the
                    // destination, ...) is a host-side failure and must not be silently
                    // downgraded to "one weird archive entry we skipped".
                    guard errno == EEXIST || errno == ELOOP else {
                        throw ArchiveUtilityError.archiveWriteFailed("\(rawPath): open failed (errno \(errno))")
                    }
                    rejectedPaths.append(rawPath)
                    continue
                }
                defer { close(fd) }
                try copy(dataReader: dataReader, to: fd, path: rawPath, buffer: &copyBuffer)
                guard fchmod(fd, mode_t(entry.permissions & 0o777)) == 0 else {
                    throw ArchiveUtilityError.archiveWriteFailed("\(rawPath): fchmod failed (errno \(errno))")
                }
                if let modificationDate = entry.modificationDate {
                    do {
                        try fileManager.setAttributes([.modificationDate: modificationDate], ofItemAtPath: fullPath.path)
                    } catch {
                        throw ArchiveUtilityError.archiveWriteFailed("\(rawPath): failed to set modification date: \(error)")
                    }
                }
            case .symbolicLink:
                guard let target = entry.symlinkTarget else {
                    rejectedPaths.append(rawPath)
                    continue
                }
                // The link is resolved by whatever later walks the extracted tree (e.g. a
                // build step reading through the context), so a target that would escape
                // `destination` is a real traversal even though extraction itself never
                // follows it. An absolute target (e.g. `/bin/sh -> /bin/busybox`, common in
                // real image layers) is interpreted relative to the extracted tree's own
                // root the same way `safeDestination` re-roots an absolute entry path —
                // rejecting every absolute symlink outright would break ordinary archives,
                // not just malicious ones. `resolvedTarget` is used for containment/ancestor
                // validation only; the on-disk link is written as a RELATIVE path (computed
                // below) so it still resolves correctly if the extracted tree is later moved
                // or copied elsewhere — baking in the transient extraction destination's own
                // absolute path would leave the link dangling the moment that happens.
                let isAbsoluteTarget = target.hasPrefix("/")
                let resolvedTarget =
                    isAbsoluteTarget
                    ? destination.appendingPathComponent(String(target.dropFirst())).standardizedFileURL
                    : fullPath.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
                guard resolvedTarget.path == destinationPath || resolvedTarget.path.hasPrefix(destinationPath + "/") else {
                    rejectedPaths.append(rawPath)
                    continue
                }
                // The lexical containment check above only looks at the target's own path
                // string — it can't detect that an intermediate component was already
                // created as a symlink by an EARLIER entry in this same archive (e.g. `a/link
                // -> /etc`, itself validated as contained), which would redirect a later
                // symlink's actual resolution (`b/x -> ../a/link/passwd`, lexically
                // "contained" as a string) outside `destination` once something dereferences
                // it. Reuse the same ancestor-symlink check already applied to the entry's own
                // path against the TARGET's path too.
                guard hasSafeAncestors(of: resolvedTarget, under: destination) else {
                    rejectedPaths.append(rawPath)
                    continue
                }
                try fileManager.createDirectory(at: fullPath.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.removeItem(at: fullPath)
                // "Last entry wins" (matching `.regular`/`.directory`) — but unlike those,
                // if `removeItem` didn't actually clear the path, `createSymbolicLink` would
                // throw and abort the WHOLE extraction rather than just this one entry. Check
                // via `lstat` (not `fileExists`, which follows symlinks and would misreport a
                // still-present but now-dangling symlink as "gone") and reject through the
                // normal per-entry path instead.
                var residualInfo = stat()
                guard lstat(fullPath.path, &residualInfo) != 0 else {
                    rejectedPaths.append(rawPath)
                    continue
                }
                let linkDestination = isAbsoluteTarget ? relativePath(from: fullPath.deletingLastPathComponent(), to: resolvedTarget) : target
                try fileManager.createSymbolicLink(atPath: fullPath.path, withDestinationPath: linkDestination)
            default:
                // Hard links are handled above (regardless of `fileType`) before this switch
                // is ever reached. Anything else libarchive might surface (FIFOs, device
                // nodes, ...) lands here — the framework's own `extractEntry` has no support
                // for them either (its `default: return false`). Unlike a path-traversal/symlink
                // violation above, this is just an unsupported (not hostile) tar feature a
                // real build context can legitimately contain — logged for visibility, but
                // not fatal to the rest of the extraction.
                unsupportedPaths.append(rawPath)
            }
        }

        if !unsupportedPaths.isEmpty {
            logger?.warning("Archive contained unsupported entries, skipped: \(unsupportedPaths.joined(separator: ", "))")
        }

        // Applied only now that every entry (including any of this directory's own children)
        // has already been created — a restrictive mode set immediately, per the comment on
        // `pendingDirectoryPermissions` above, could otherwise block creating later entries.
        // Reversed (deepest child first): chmod'ing a path requires execute/search permission
        // on every ancestor directory to resolve it — applying a restrictive parent mode
        // before a still-pending child chmod underneath it could make that child's own path
        // unresolvable.
        for (path, mode) in pendingDirectoryPermissions.reversed() {
            try? fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }

        guard foundEntry else {
            throw ArchiveUtilityError.archiveReadFailed("no entries found in archive")
        }
        return rejectedPaths
    }

    /// Verifies no ancestor directory between `destination` and `fullPath` is itself a
    /// symlink (see the call site's comment for the attack this closes). Not fully
    /// TOC-TOU-atomic (an `openat`-relative-fd walk would be) — but extraction here is
    /// single-threaded and sequential over an archive nothing else is concurrently
    /// mutating, so the realistic threat is the archive planting the symlink itself,
    /// which this reliably catches.
    private static func hasSafeAncestors(of fullPath: URL, under destination: URL) -> Bool {
        let destinationPath = destination.standardizedFileURL.path
        var current = fullPath.deletingLastPathComponent().standardizedFileURL
        // `hasPrefix(destinationPath + "/")` (not bare `destinationPath`), matching
        // `safeDestination`'s own boundary check — otherwise a sibling directory like
        // `<destinationPath>-evil` would incorrectly be treated as an ancestor under
        // `destination`.
        while current.path.hasPrefix(destinationPath + "/") {
            var info = stat()
            if lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                return false
            }
            current = current.deletingLastPathComponent()
        }
        return true
    }

    /// Computes the relative path from `sourceDir` to `target` (e.g. `../etc/passwd`),
    /// so an absolute symlink target can be re-rooted under `destination` for containment
    /// checking while still being WRITTEN to disk as a portable, relative link — one that
    /// keeps resolving correctly if the extracted tree is later moved or copied elsewhere,
    /// unlike baking in the transient extraction destination's own absolute path.
    private static func relativePath(from sourceDir: URL, to target: URL) -> String {
        let sourceComponents = sourceDir.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var shared = 0
        while shared < sourceComponents.count, shared < targetComponents.count, sourceComponents[shared] == targetComponents[shared] {
            shared += 1
        }
        let ups = Array(repeating: "..", count: sourceComponents.count - shared)
        let downs = targetComponents[shared...]
        let combined = ups + downs
        return combined.isEmpty ? "." : combined.joined(separator: "/")
    }

    /// Resolves a tar member path to a destination URL, rejecting absolute
    /// paths and any path that escapes `destination` (e.g. via `..` components).
    /// A root entry (`.`/`./`, which this project's own `ArchiveWriter` emits
    /// for the archive's top-level directory) resolves to `destination` itself
    /// rather than being rejected as empty.
    private static func safeDestination(for rawPath: String, under destination: URL, destinationPath: String) -> URL? {
        var relative = rawPath
        if relative.hasPrefix("./") { relative.removeFirst(2) }
        while relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty || relative == "." {
            return destination.standardizedFileURL
        }

        let fullPath = destination.appendingPathComponent(relative).standardizedFileURL
        let resolved = fullPath.path
        guard resolved == destinationPath || resolved.hasPrefix(destinationPath + "/") else {
            return nil
        }
        return fullPath
    }

    private static func copy(dataReader: ArchiveEntryReader, to fd: Int32, path: String, buffer: inout [UInt8]) throws {
        while true {
            let bytesRead = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return dataReader.read(base, maxLength: ptr.count)
            }
            guard bytesRead >= 0 else {
                throw ArchiveUtilityError.entryReadFailed(path)
            }
            if bytesRead == 0 { break }
            // `write(2)` isn't guaranteed to consume the whole buffer in one call (short
            // writes are legal, not just an error signal) — drain it, retrying a signal
            // interruption (EINTR) rather than treating either as a failure.
            var offset = 0
            while offset < bytesRead {
                errno = 0
                let written = buffer.withUnsafeBytes { raw -> Int in
                    write(fd, raw.baseAddress!.advanced(by: offset), bytesRead - offset)
                }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else {
                    throw ArchiveUtilityError.archiveWriteFailed("\(path): write failed (errno \(errno))")
                }
                offset += written
            }
        }
    }

    static func create(tarPath: URL, from source: URL) throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: source.path) else {
            throw ArchiveUtilityError.invalidPath
        }

        let writer: ArchiveWriter
        do {
            writer = try ArchiveWriter(
                format: .paxRestricted,
                filter: .none,
                file: tarPath
            )
        } catch {
            throw ArchiveUtilityError.archiveCreationFailed(error.localizedDescription)
        }

        do {
            try writer.archiveDirectory(source)
            try writer.finishEncoding()
        } catch {
            throw ArchiveUtilityError.archiveWriteFailed(error.localizedDescription)
        }
    }

    static func destinationPath(for entryPath: String?, under destinationPath: String) -> String? {
        guard var entryPath else {
            return nil
        }

        if entryPath.hasPrefix("./") {
            entryPath = String(entryPath.dropFirst(1))
        }
        if entryPath == "." || entryPath == "/" {
            return destinationPath
        }
        if !entryPath.hasPrefix("/") {
            entryPath = "/" + entryPath
        }

        if destinationPath == "/" {
            return entryPath
        }

        return destinationPath + entryPath
    }

    static func unpack(
        tarPath: URL,
        to formatter: EXT4.Formatter,
        destinationPath targetPath: String
    ) throws {
        let archiveReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: tarPath
        )

        let bufferSize = 128 * 1024
        let reusableBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bufferSize)
        defer { reusableBuffer.deallocate() }

        for (entry, streamReader) in archiveReader.makeStreamingIterator() {
            guard let fullPath = destinationPath(for: entry.path, under: targetPath) else {
                continue
            }

            let filePath = FilePath(fullPath)
            let ts = FileTimestamps(
                access: entry.contentAccessDate,
                modification: entry.modificationDate,
                creation: entry.creationDate
            )

            switch entry.fileType {
            case .directory:
                try formatter.create(
                    path: filePath,
                    mode: EXT4.Inode.Mode(.S_IFDIR, entry.permissions),
                    ts: ts,
                    uid: entry.owner,
                    gid: entry.group,
                    xattrs: entry.xattrs
                )
            case .regular:
                try formatter.create(
                    path: filePath,
                    mode: EXT4.Inode.Mode(.S_IFREG, entry.permissions),
                    ts: ts,
                    buf: streamReader,
                    uid: entry.owner,
                    gid: entry.group,
                    xattrs: entry.xattrs,
                    fileBuffer: reusableBuffer
                )
            case .symbolicLink:
                let symlinkTarget = entry.symlinkTarget.map { FilePath($0) }
                try formatter.create(
                    path: filePath,
                    link: symlinkTarget,
                    mode: EXT4.Inode.Mode(.S_IFLNK, entry.permissions),
                    ts: ts,
                    uid: entry.owner,
                    gid: entry.group,
                    xattrs: entry.xattrs
                )
            default:
                continue
            }
        }
    }
}
