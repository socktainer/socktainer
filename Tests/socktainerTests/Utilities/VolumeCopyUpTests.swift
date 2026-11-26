import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import Logging
import SystemPackage
import Testing

@testable import socktainer

@Suite("VolumeCopyUp — Docker's copy-up onto an empty named volume")
final class VolumeCopyUpTests {
    private let logger = Logger(label: "test")

    @Test("a fresh volume counts as empty, one with contents does not")
    func recognisesAnEmptyVolume() throws {
        let fixture = CopyUpFixture()
        defer { fixture.cleanUp() }

        try fixture.makeVolume()
        #expect(VolumeCopyUp.isEmpty(volumeImagePath: fixture.volume.path))

        try fixture.makeRootfs { formatter in
            try formatter.create(path: FilePath("/data"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try fixture.writeFile(formatter, "/data/seed.txt", "hello\n", mode: 0o640)
        }
        try VolumeCopyUp.populate(
            volumeImagePath: fixture.volume.path, fromRootfs: fixture.rootfs.path,
            sourcePath: "/data", logger: logger)

        #expect(!VolumeCopyUp.isEmpty(volumeImagePath: fixture.volume.path))
    }

    @Test("contents, ownership and permissions arrive at the volume root")
    func copiesOwnershipAndPermissions() throws {
        let fixture = CopyUpFixture()
        defer { fixture.cleanUp() }
        try fixture.makeVolume()
        try fixture.makeRootfs { formatter in
            try formatter.create(
                path: FilePath("/data"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o750),
                uid: 1000, gid: 1000)
            try fixture.writeFile(formatter, "/data/seed.txt", "hello\n", mode: 0o640, uid: 1000, gid: 1000)
        }

        try VolumeCopyUp.populate(
            volumeImagePath: fixture.volume.path, fromRootfs: fixture.rootfs.path,
            sourcePath: "/data", logger: logger)

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(fixture.volume.path))
        let (_, root) = try reader.stat(FilePath("/"))
        #expect(root.fullUid == 1000)
        #expect(root.fullGid == 1000)
        #expect(root.mode & 0o777 == 0o750)

        let (_, file) = try reader.stat(FilePath("/seed.txt"))
        #expect(file.fullUid == 1000)
        #expect(file.mode & 0o777 == 0o640)
        #expect(try reader.readFile(at: FilePath("/seed.txt")) == Data("hello\n".utf8))
    }

    @Test("the rebuild leaves no /lost+found behind")
    func dropsLostAndFound() throws {
        let fixture = CopyUpFixture()
        defer { fixture.cleanUp() }
        try fixture.makeVolume()
        #expect(
            try EXT4.EXT4Reader(blockDevice: FilePath(fixture.volume.path))
                .listDirectory(FilePath("/")).contains("lost+found"))

        try fixture.makeRootfs { formatter in
            try formatter.create(path: FilePath("/data"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        }
        try VolumeCopyUp.populate(
            volumeImagePath: fixture.volume.path, fromRootfs: fixture.rootfs.path,
            sourcePath: "/data", logger: logger)

        let entries = try EXT4.EXT4Reader(blockDevice: FilePath(fixture.volume.path))
            .listDirectory(FilePath("/"))
        #expect(!entries.contains("lost+found"))
    }

    @Test("nested directories and symlinks survive the copy")
    func copiesTreeAndSymlinks() throws {
        let fixture = CopyUpFixture()
        defer { fixture.cleanUp() }
        try fixture.makeVolume()
        try fixture.makeRootfs { formatter in
            try formatter.create(path: FilePath("/data"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try formatter.create(path: FilePath("/data/nested"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try fixture.writeFile(formatter, "/data/nested/deep.txt", "deep\n", mode: 0o644)
            try formatter.create(
                path: FilePath("/data/link"), link: FilePath("/nested/deep.txt"),
                mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
        }

        // The fixture has to hold a symlink before the copy can be blamed for one.
        let sourceReader = try EXT4.EXT4Reader(blockDevice: FilePath(fixture.rootfs.path))
        #expect(try sourceReader.listDirectory(FilePath("/data")).contains("link"))

        try VolumeCopyUp.populate(
            volumeImagePath: fixture.volume.path, fromRootfs: fixture.rootfs.path,
            sourcePath: "/data", logger: logger)

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(fixture.volume.path))
        #expect(try reader.readFile(at: FilePath("/nested/deep.txt")) == Data("deep\n".utf8))
        let (_, link) = try reader.stat(FilePath("/link"), followSymlinks: false)
        #expect(link.isSymlink)
    }

    @Test("a file larger than one read buffer arrives whole")
    func copiesLargeFileInChunks() throws {
        let fixture = CopyUpFixture()
        defer { fixture.cleanUp() }
        try fixture.makeVolume()
        let payload = String(repeating: "abcdefgh", count: 200_000)  // 1.6 MB
        try fixture.makeRootfs { formatter in
            try formatter.create(path: FilePath("/data"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try fixture.writeFile(formatter, "/data/big.bin", payload, mode: 0o644)
        }

        try VolumeCopyUp.populate(
            volumeImagePath: fixture.volume.path, fromRootfs: fixture.rootfs.path,
            sourcePath: "/data", logger: logger)

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(fixture.volume.path))
        #expect(try reader.readFile(at: FilePath("/big.bin")) == Data(payload.utf8))
    }

    @Test("a second name for a file stays a hard link, not a second copy")
    func copiesHardLinksAsLinks() throws {
        let fixture = CopyUpFixture()
        defer { fixture.cleanUp() }
        try fixture.makeVolume()
        try fixture.makeRootfs { formatter in
            try formatter.create(path: FilePath("/data"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try fixture.writeFile(formatter, "/data/original.txt", "shared\n", mode: 0o644)
            try formatter.link(link: FilePath("/data/second.txt"), target: FilePath("/data/original.txt"))
        }

        try VolumeCopyUp.populate(
            volumeImagePath: fixture.volume.path, fromRootfs: fixture.rootfs.path,
            sourcePath: "/data", logger: logger)

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(fixture.volume.path))
        let (firstNumber, first) = try reader.stat(FilePath("/original.txt"))
        let (secondNumber, _) = try reader.stat(FilePath("/second.txt"))
        #expect(firstNumber == secondNumber)
        #expect(first.linksCount == 2)
        #expect(try reader.readFile(at: FilePath("/second.txt")) == Data("shared\n".utf8))
    }

    @Test("an image with nothing at the mount path still yields a usable volume")
    func handlesMissingSourcePath() throws {
        let fixture = CopyUpFixture()
        defer { fixture.cleanUp() }
        try fixture.makeVolume()
        try fixture.makeRootfs { formatter in
            try formatter.create(path: FilePath("/other"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        }

        try VolumeCopyUp.populate(
            volumeImagePath: fixture.volume.path, fromRootfs: fixture.rootfs.path,
            sourcePath: "/data", logger: logger)

        let entries = try EXT4.EXT4Reader(blockDevice: FilePath(fixture.volume.path))
            .listDirectory(FilePath("/"))
        #expect(!entries.contains("lost+found"))
    }

    @Test("copying a file reads its source once per MiB, not once per 4 KiB block")
    func readsSourceOncePerMiB() throws {
        let fixture = CopyUpFixture()
        defer { fixture.cleanUp() }
        try fixture.makeVolume(size: 16 * 1024 * 1024)
        let payload = blockDistinctBytes(count: 8 * 1024 * 1024)
        try fixture.makeRootfs { formatter in
            try formatter.create(path: FilePath("/data"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try fixture.writeFile(formatter, "/data/lib.jar", payload, mode: 0o644)
        }
        let sourceReads = ReadCounter()

        try VolumeCopyUp.populate(
            volumeImagePath: fixture.volume.path, fromRootfs: fixture.rootfs.path,
            sourcePath: "/data", logger: logger,
            fileContents: { reader, path, size in
                CountingStream(VolumeCopyUp.ext4FileContents(reader, path, size), counter: sourceReads)
            })

        #expect(sourceReads.count == 8)
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(fixture.volume.path))
        #expect(try reader.readFile(at: FilePath("/lib.jar")) == payload)
    }

    @Test("files sized around the read buffer boundary arrive byte for byte")
    func copiesBufferBoundarySizesExactly() throws {
        let fixture = CopyUpFixture()
        defer { fixture.cleanUp() }
        try fixture.makeVolume(size: 16 * 1024 * 1024)
        let mebibyte = 1024 * 1024
        let files: [String: Data] = [
            "empty.txt": Data(),
            "one-byte.txt": blockDistinctBytes(count: 1),
            "just-under.bin": blockDistinctBytes(count: mebibyte - 1),
            "exact.bin": blockDistinctBytes(count: mebibyte),
            "just-over.bin": blockDistinctBytes(count: mebibyte + 1),
            "several.bin": blockDistinctBytes(count: 3 * mebibyte + mebibyte / 2),
        ]
        try fixture.makeRootfs { formatter in
            try formatter.create(path: FilePath("/data"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            for (name, contents) in files {
                try fixture.writeFile(formatter, "/data/\(name)", contents, mode: 0o644)
            }
        }

        try VolumeCopyUp.populate(
            volumeImagePath: fixture.volume.path, fromRootfs: fixture.rootfs.path,
            sourcePath: "/data", logger: logger)

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(fixture.volume.path))
        for (name, contents) in files {
            #expect(try reader.readFile(at: FilePath("/\(name)")) == contents, "\(name)")
        }
    }

    @Test("repeated copy-ups from one image open its filesystem once")
    func opensRootfsOncePerImage() throws {
        let fixture = CopyUpFixture()
        defer { fixture.cleanUp() }
        try fixture.makeRootfs { formatter in
            try formatter.create(path: FilePath("/data"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try fixture.writeFile(formatter, "/data/seed.txt", "hello\n", mode: 0o644)
        }
        let opens = ReadCounter()
        let readers = FileReaderCache<EXT4.EXT4Reader>(capacity: 4, idleTimeout: .seconds(300)) { path in
            opens.increment()
            return try EXT4.EXT4Reader(blockDevice: FilePath(path))
        }

        for volume in try fixture.makeVolumes(count: 3) {
            try VolumeCopyUp.populate(
                volumeImagePath: volume.path, fromRootfs: fixture.rootfs.path,
                sourcePath: "/data", logger: logger, readers: readers)
            let reader = try EXT4.EXT4Reader(blockDevice: FilePath(volume.path))
            #expect(try reader.readFile(at: FilePath("/seed.txt")) == Data("hello\n".utf8))
        }

        #expect(opens.count == 1)
    }

    @Test("parallel copy-ups from one image each get the full contents")
    func parallelCopyUpsShareTheReaderSafely() throws {
        let fixture = CopyUpFixture()
        defer { fixture.cleanUp() }
        let payload = blockDistinctBytes(count: 2 * 1024 * 1024 + 4097)
        try fixture.makeRootfs { formatter in
            try formatter.create(path: FilePath("/data"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try fixture.writeFile(formatter, "/data/state.db", payload, mode: 0o644)
        }
        let volumes = try fixture.makeVolumes(count: 6)
        let readers = FileReaderCache<EXT4.EXT4Reader>(capacity: 4, idleTimeout: .seconds(300)) { path in
            try EXT4.EXT4Reader(blockDevice: FilePath(path))
        }
        let logger = self.logger

        DispatchQueue.concurrentPerform(iterations: volumes.count) { index in
            try? VolumeCopyUp.populate(
                volumeImagePath: volumes[index].path, fromRootfs: fixture.rootfs.path,
                sourcePath: "/data", logger: logger, readers: readers)
        }

        for volume in volumes {
            let reader = try EXT4.EXT4Reader(blockDevice: FilePath(volume.path))
            #expect(try reader.readFile(at: FilePath("/state.db")) == payload)
        }
    }
}

// MARK: - Fixture

private struct CopyUpFixture {
    let directory: URL
    let volume: URL
    let rootfs: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("copyup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        volume = directory.appendingPathComponent("volume.img")
        rootfs = directory.appendingPathComponent("rootfs.ext4")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A volume as Apple Container hands it over: empty apart from /lost+found.
    func makeVolume(size: UInt64 = 8 * 1024 * 1024) throws {
        try Self.formatEmptyVolume(at: volume, size: size)
    }

    func makeVolumes(count: Int) throws -> [URL] {
        try (0..<count).map { index in
            let url = directory.appendingPathComponent("volume-\(index).img")
            try Self.formatEmptyVolume(at: url, size: 16 * 1024 * 1024)
            return url
        }
    }

    private static func formatEmptyVolume(at url: URL, size: UInt64) throws {
        let formatter = try EXT4.Formatter(FilePath(url.path), blockSize: 4096, minDiskSize: size)
        try formatter.close()
    }

    func makeRootfs(_ build: (EXT4.Formatter) throws -> Void) throws {
        let formatter = try EXT4.Formatter(FilePath(rootfs.path), blockSize: 4096, minDiskSize: 32 * 1024 * 1024)
        try build(formatter)
        try formatter.close()
    }

    func writeFile(
        _ formatter: EXT4.Formatter, _ path: String, _ contents: String,
        mode: UInt16, uid: UInt32 = 0, gid: UInt32 = 0
    ) throws {
        try writeFile(formatter, path, Data(contents.utf8), mode: mode, uid: uid, gid: gid)
    }

    func writeFile(
        _ formatter: EXT4.Formatter, _ path: String, _ contents: Data,
        mode: UInt16, uid: UInt32 = 0, gid: UInt32 = 0
    ) throws {
        let stream = InputStream(data: contents)
        stream.open()
        defer { stream.close() }
        try formatter.create(
            path: FilePath(path), mode: EXT4.Inode.Mode(.S_IFREG, mode),
            buf: stream, uid: uid, gid: gid)
    }
}

private func blockDistinctBytes(count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 12)) })
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() {
        lock.withLock { value += 1 }
    }
}

private final class CountingStream: ReadableStream {
    private let base: any ReadableStream
    private let counter: ReadCounter

    init(_ base: any ReadableStream, counter: ReadCounter) {
        self.base = base
        self.counter = counter
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int {
        let read = base.read(buffer, maxLength: maxLength)
        if read > 0 { counter.increment() }
        return read
    }
}
