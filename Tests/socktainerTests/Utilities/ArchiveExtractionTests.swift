import ContainerizationArchive
import Foundation
import Testing

@testable import socktainer

/// `ArchiveReader.extractContents(to:)` (the vendored Containerization framework) creates
/// regular files via `open(O_CREAT | O_EXCL | O_WRONLY, entry.permissions)`, using the
/// entry's own recorded mode as the create mode — which fails with EACCES on macOS for any
/// entry whose mode has no owner-write bit (e.g. real build contexts containing read-only
/// vendored/test binaries like kubebuilder's envtest `etcd`). `ArchiveUtility.extract`
/// reimplements extraction over the framework's public streaming iterator specifically to
/// avoid this.
@Suite("ArchiveUtility.extract — read-only entries")
struct ArchiveExtractionReadOnlyTests {
    @Test("A tar entry with no owner-write bit extracts instead of failing with EACCES")
    func readOnlyFileExtracts() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let readOnlyFile = source.appendingPathComponent("readonly-binary")
        try "not a real binary, just needs a read-only mode".data(using: .utf8)!.write(to: readOnlyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyFile.path)

        let tar = tmp.appendingPathComponent("context.tar")
        try ArchiveUtility.create(tarPath: tar, from: source)

        let dest = tmp.appendingPathComponent("out")
        try ArchiveUtility.extract(tarPath: tar, to: dest)

        let extractedPath = dest.appendingPathComponent("readonly-binary")
        #expect(FileManager.default.fileExists(atPath: extractedPath.path))
        let extracted = try String(contentsOf: extractedPath, encoding: .utf8)
        #expect(extracted == "not a real binary, just needs a read-only mode")

        // The real (read-only) mode is preserved via a post-write chmod, not lost by
        // creating the file writable to work around the EACCES bug.
        let attrs = try FileManager.default.attributesOfItem(atPath: extractedPath.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        #expect(mode & 0o200 == 0)  // no owner-write bit
        #expect(mode & 0o500 == 0o500)  // owner read+execute preserved
    }
}

/// `ArchiveUtility.extract` creates regular files via `open(..., O_EXCL | O_NOFOLLOW, ...)`
/// and rejects any tar member path that resolves outside the destination directory — closing
/// the path-traversal and symlink-planting attacks a malicious tarball (e.g. one loaded via
/// `docker load`/`import`) could otherwise use to write outside the extraction directory.
@Suite("ArchiveUtility.extract — path safety")
struct ArchiveExtractionSafetyTests {
    @Test("The archive's own root entry ('./') resolves to the destination itself, not rejected as empty")
    func rootEntryIsDestination() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "hello".data(using: .utf8)!.write(to: source.appendingPathComponent("file.txt"))

        // ArchiveWriter.archiveDirectory (used internally by ArchiveUtility.create for the
        // load/import path) emits a leading "./" entry for the archive's own root directory.
        let tar = tmp.appendingPathComponent("context.tar")
        try ArchiveUtility.create(tarPath: tar, from: source)

        let dest = tmp.appendingPathComponent("out")
        // Must not throw .rejectedArchiveEntries(["./"]) or similar.
        try ArchiveUtility.extract(tarPath: tar, to: dest)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("file.txt").path))
    }

    @Test("A raw '../' traversal path is rejected and nothing is written outside the destination")
    func traversalPathIsRejected() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tar = tmp.appendingPathComponent("malicious.tar")
        try writeRawTar(
            at: tar,
            entries: [RawTarEntry(path: "../escape", fileType: .regular, data: Data("pwned".utf8))])

        let dest = tmp.appendingPathComponent("out")
        do {
            try ArchiveUtility.extract(tarPath: tar, to: dest)
            Issue.record("expected extraction to reject the traversal entry")
        } catch ArchiveUtilityError.rejectedArchiveEntries(let paths) {
            #expect(paths.contains("../escape"))
        }
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("escape").path))
    }

    @Test("A path entry that traverses an already-extracted symlink ancestor is rejected")
    func symlinkAncestorTraversalIsRejected() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // `evil -> <outside>` is itself a valid, contained symlink entry (an absolute target
        // is re-rooted under the destination) — but a later entry whose path runs *through*
        // it (`evil/pwned`) must still be rejected, since normal path resolution would
        // transparently follow `evil` outside the destination tree.
        let outside = tmp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let tar = tmp.appendingPathComponent("malicious.tar")
        try writeRawTar(
            at: tar,
            entries: [
                RawTarEntry(path: "evil", fileType: .symbolicLink, symlinkTarget: outside.path),
                RawTarEntry(path: "evil/pwned", fileType: .regular, data: Data("pwned".utf8)),
            ])

        let dest = tmp.appendingPathComponent("out")
        do {
            try ArchiveUtility.extract(tarPath: tar, to: dest)
            Issue.record("expected extraction to reject the symlink-ancestor traversal entry")
        } catch ArchiveUtilityError.rejectedArchiveEntries(let paths) {
            #expect(paths.contains("evil/pwned"))
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("pwned").path))
    }

    @Test("A symlink whose target chains through an earlier already-extracted symlink is rejected")
    func chainedSymlinkTargetTraversalIsRejected() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // `a/link -> /etc` is contained (re-rooted under the destination as `a/link ->
        // <dest>/etc`). A later symlink `b/x -> ../a/link/passwd` is lexically "contained"
        // as a string (it never leaves `<dest>` when the `..` is collapsed textually), but
        // resolving it for real means walking through `a/link`, which redirects outside the
        // destination the moment something dereferences `b/x`.
        let tar = tmp.appendingPathComponent("malicious.tar")
        try writeRawTar(
            at: tar,
            entries: [
                RawTarEntry(path: "a", fileType: .directory),
                RawTarEntry(path: "a/link", fileType: .symbolicLink, symlinkTarget: "/etc"),
                RawTarEntry(path: "b", fileType: .directory),
                RawTarEntry(path: "b/x", fileType: .symbolicLink, symlinkTarget: "../a/link/passwd"),
            ])

        let dest = tmp.appendingPathComponent("out")
        do {
            try ArchiveUtility.extract(tarPath: tar, to: dest)
            Issue.record("expected extraction to reject the chained-symlink traversal entry")
        } catch ArchiveUtilityError.rejectedArchiveEntries(let paths) {
            #expect(paths.contains("b/x"))
        }
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("b/x").path))
    }

    @Test("An absolute symlink target is written to disk as a relative link, not the transient extraction path")
    func absoluteSymlinkTargetIsWrittenRelative() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tar = tmp.appendingPathComponent("context.tar")
        try writeRawTar(
            at: tar,
            entries: [
                RawTarEntry(path: "bin", fileType: .directory),
                RawTarEntry(path: "bin/sh", fileType: .symbolicLink, symlinkTarget: "/bin/busybox"),
            ])

        let dest = tmp.appendingPathComponent("out")
        try ArchiveUtility.extract(tarPath: tar, to: dest)

        let linkPath = dest.appendingPathComponent("bin/sh").path
        let onDiskTarget = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        // Not an absolute path baked to this extraction's own (transient) destination —
        // that would dangle the moment the extracted tree is moved or copied elsewhere.
        #expect(!onDiskTarget.hasPrefix("/"))
        #expect(onDiskTarget == "busybox")
    }

    @Test("An unsupported entry type (e.g. a FIFO) is skipped without failing the whole extraction")
    func unsupportedEntryTypeIsNonFatal() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tar = tmp.appendingPathComponent("context.tar")
        try writeRawTar(
            at: tar,
            entries: [
                RawTarEntry(path: "a-fifo", fileType: .namedPipe),
                RawTarEntry(path: "file.txt", fileType: .regular, data: Data("hello".utf8)),
            ])

        let dest = tmp.appendingPathComponent("out")
        // Must not throw — a FIFO is an unsupported-but-benign tar feature, unlike a
        // path-traversal/symlink-planting violation.
        try ArchiveUtility.extract(tarPath: tar, to: dest)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("file.txt").path))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("a-fifo").path))
    }

    @Test("A regular file's recorded modification time is preserved on extraction")
    func modificationDateIsPreserved() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Tar mtimes are second-granularity — round to the nearest second so the
        // round-trip comparison below isn't sensitive to sub-second truncation.
        let recordedDate = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 86400)
        let tar = tmp.appendingPathComponent("context.tar")
        try writeRawTar(
            at: tar,
            entries: [
                RawTarEntry(path: "file.txt", fileType: .regular, data: Data("hello".utf8), modificationDate: recordedDate)
            ])

        let dest = tmp.appendingPathComponent("out")
        try ArchiveUtility.extract(tarPath: tar, to: dest)

        let attrs = try FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent("file.txt").path)
        let extractedDate = attrs[.modificationDate] as? Date
        #expect(extractedDate != nil)
        #expect(abs((extractedDate ?? .distantPast).timeIntervalSince(recordedDate)) < 1)
    }

    @Test("A directory entry reusing a path a prior symlink entry occupied becomes a real directory, not a dangling symlink")
    func directoryEntryReplacesPriorSymlink() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tar = tmp.appendingPathComponent("context.tar")
        try writeRawTar(
            at: tar,
            entries: [
                RawTarEntry(path: "real_target", fileType: .directory),
                // "evil" first arrives as a symlink to an existing (contained) directory —
                // `fileManager.fileExists(atPath:isDirectory:)` would follow it and report
                // "already a directory," skipping removal; only `lstat` sees the symlink.
                RawTarEntry(path: "evil", fileType: .symbolicLink, symlinkTarget: "real_target"),
                // A later entry corrects "evil" to be a real directory — "last entry wins,"
                // matching the `.regular` case's own semantics.
                RawTarEntry(path: "evil", fileType: .directory),
            ])

        let dest = tmp.appendingPathComponent("out")
        try ArchiveUtility.extract(tarPath: tar, to: dest)

        let evilPath = dest.appendingPathComponent("evil").path
        var info = stat()
        #expect(lstat(evilPath, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFDIR)
    }

    @Test("A hard-link entry links to its target's real content, not an empty file")
    func hardLinkEntryLinksToTargetContent() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tar = tmp.appendingPathComponent("context.tar")
        try writeRawTar(
            at: tar,
            entries: [
                RawTarEntry(path: "original.txt", fileType: .regular, data: Data("hello, hardlink".utf8)),
                // A hard-link entry surfaces with `fileType == .regular` (see `archive_entry_hardlink`
                // convention) and no data of its own — the entry itself only carries the linked-to
                // path.
                RawTarEntry(path: "linked.txt", fileType: .regular, hardlinkTarget: "original.txt"),
            ])

        let dest = tmp.appendingPathComponent("out")
        try ArchiveUtility.extract(tarPath: tar, to: dest)

        let originalPath = dest.appendingPathComponent("original.txt").path
        let linkedPath = dest.appendingPathComponent("linked.txt").path
        let linkedContent = try String(contentsOfFile: linkedPath, encoding: .utf8)
        #expect(linkedContent == "hello, hardlink")

        var originalInfo = stat()
        var linkedInfo = stat()
        #expect(stat(originalPath, &originalInfo) == 0)
        #expect(stat(linkedPath, &linkedInfo) == 0)
        #expect(originalInfo.st_ino == linkedInfo.st_ino)
    }

    @Test("A hard-link entry resolving to the extraction root itself is rejected, not linked over the destination directory")
    func hardLinkEntryAtDestinationRootIsRejected() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tar = tmp.appendingPathComponent("malicious.tar")
        try writeRawTar(
            at: tar,
            entries: [
                RawTarEntry(path: "sentinel.txt", fileType: .regular, data: Data("sentinel".utf8)),
                // A "."/root-path hard-link entry would otherwise `removeItem` the destination
                // directory itself before re-linking it — reject it instead of processing it.
                RawTarEntry(path: ".", fileType: .regular, hardlinkTarget: "sentinel.txt"),
            ])

        let dest = tmp.appendingPathComponent("out")
        do {
            try ArchiveUtility.extract(tarPath: tar, to: dest)
            Issue.record("expected extraction to reject the root hard-link entry")
        } catch ArchiveUtilityError.rejectedArchiveEntries(let paths) {
            #expect(paths.contains("."))
        }
        // The destination directory itself must have survived, still able to hold the
        // sentinel entry that was extracted before the malicious root entry was rejected.
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("sentinel.txt").path))
    }
}

private struct RawTarEntry {
    let path: String
    let fileType: URLFileResourceType
    var symlinkTarget: String? = nil
    var hardlinkTarget: String? = nil
    var data: Data? = nil
    var modificationDate: Date? = nil
}

/// Writes a tar with entries exactly as specified, bypassing `ArchiveUtility.create`'s
/// real-directory-archiving convenience — needed to construct entries a real filesystem
/// could never produce directly (a raw `../` path, or a symlink chain planted deliberately).
private func writeRawTar(at tarPath: URL, entries: [RawTarEntry]) throws {
    let writer = try ArchiveWriter(format: .paxRestricted, filter: .none, file: tarPath)
    for raw in entries {
        let entry = WriteEntry(writer)
        entry.path = raw.path
        entry.fileType = raw.fileType
        entry.permissions = raw.fileType == .directory ? 0o755 : 0o644
        if let target = raw.symlinkTarget {
            entry.symlinkTarget = target
        }
        if let target = raw.hardlinkTarget {
            entry.hardlink = target
        }
        if let modificationDate = raw.modificationDate {
            entry.modificationDate = modificationDate
        }
        if let data = raw.data {
            entry.size = Int64(data.count)
            try writer.writeEntry(entry: entry, data: data)
        } else {
            entry.size = 0
            try writer.writeEntry(entry: entry, data: nil as UnsafeRawBufferPointer?)
        }
    }
    try writer.finishEncoding()
}
