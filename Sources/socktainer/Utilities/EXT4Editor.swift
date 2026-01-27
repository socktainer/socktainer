import ContainerizationEXT4
import Foundation
import SystemPackage


/// EXT4 filesystem constants
private enum EXT4Constants {
    static let superBlockOffset: UInt64 = 1024
    static let superBlockMagic: UInt16 = 0xEF53
    static let extentHeaderMagic: UInt16 = 0xF30A
    static let rootInode: UInt32 = 2
    static let firstInode: UInt32 = 11
    static let inodeSize: UInt32 = 256
}


/// Errors specific to EXT4Editor operations
public enum EXT4EditorError: Error, LocalizedError {
    case fileNotFound(String)
    case invalidSuperBlock
    case invalidMagic
    case noFreeBlocks
    case noFreeInodes
    case parentNotFound(String)
    case parentNotDirectory(String)
    case fileAlreadyExists(String)
    case directoryFull(String)
    case writeError(String)
    case readError(String)
    case invalidPath(String)
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "File not found: \(path)"
        case .invalidSuperBlock: return "Invalid superblock"
        case .invalidMagic: return "Invalid magic number"
        case .noFreeBlocks: return "No free blocks available"
        case .noFreeInodes: return "No free inodes available"
        case .parentNotFound(let path): return "Parent directory not found: \(path)"
        case .parentNotDirectory(let path): return "Parent is not a directory: \(path)"
        case .fileAlreadyExists(let path): return "File already exists: \(path)"
        case .directoryFull(let path): return "Directory is full: \(path)"
        case .writeError(let msg): return "Write error: \(msg)"
        case .readError(let msg): return "Read error: \(msg)"
        case .invalidPath(let path): return "Invalid path: \(path)"
        case .notImplemented(let feature): return "Not implemented: \(feature)"
        }
    }
}


/// On-disk superblock structure (matches Apple's EXT4.SuperBlock layout)
struct EXT4SuperBlock {
    var inodesCount: UInt32 = 0
    var blocksCountLow: UInt32 = 0
    var rootBlocksCountLow: UInt32 = 0
    var freeBlocksCountLow: UInt32 = 0
    var freeInodesCount: UInt32 = 0
    var firstDataBlock: UInt32 = 0
    var logBlockSize: UInt32 = 0
    var logClusterSize: UInt32 = 0
    var blocksPerGroup: UInt32 = 0
    var clustersPerGroup: UInt32 = 0
    var inodesPerGroup: UInt32 = 0
    var mtime: UInt32 = 0
    var wtime: UInt32 = 0
    var mountCount: UInt16 = 0
    var maxMountCount: UInt16 = 0
    var magic: UInt16 = 0
    var state: UInt16 = 0
    var errors: UInt16 = 0
    var minorRevisionLevel: UInt16 = 0
    var lastCheck: UInt32 = 0
    var checkInterval: UInt32 = 0
    var creatorOS: UInt32 = 0
    var revisionLevel: UInt32 = 0
    var defaultReservedUid: UInt16 = 0
    var defaultReservedGid: UInt16 = 0
    var firstInode: UInt32 = 0
    var inodeSize: UInt16 = 0
    var blockGroupNr: UInt16 = 0
    var featureCompat: UInt32 = 0
    var featureIncompat: UInt32 = 0
    var featureRoCompat: UInt32 = 0
    // ... rest of superblock fields (we only need the above for our purposes)
}

/// On-disk group descriptor structure
struct EXT4GroupDescriptor {
    var blockBitmapLow: UInt32 = 0
    var inodeBitmapLow: UInt32 = 0
    var inodeTableLow: UInt32 = 0
    var freeBlocksCountLow: UInt16 = 0
    var freeInodesCountLow: UInt16 = 0
    var usedDirsCountLow: UInt16 = 0
    var flags: UInt16 = 0
    var excludeBitmapLow: UInt32 = 0
    var blockBitmapCsumLow: UInt16 = 0
    var inodeBitmapCsumLow: UInt16 = 0
    var itableUnusedLow: UInt16 = 0
    var checksum: UInt16 = 0
}

/// On-disk inode structure
struct EXT4Inode {
    var mode: UInt16 = 0
    var uid: UInt16 = 0
    var sizeLow: UInt32 = 0
    var atime: UInt32 = 0
    var ctime: UInt32 = 0
    var mtime: UInt32 = 0
    var dtime: UInt32 = 0
    var gid: UInt16 = 0
    var linksCount: UInt16 = 0
    var blocksLow: UInt32 = 0
    var flags: UInt32 = 0
    var version: UInt32 = 0
    var block: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
    var generation: UInt32 = 0
    var xattrBlockLow: UInt32 = 0
    var sizeHigh: UInt32 = 0
    var obsoleteFragmentAddr: UInt32 = 0
    var blocksHigh: UInt16 = 0
    var xattrBlockHigh: UInt16 = 0
    var uidHigh: UInt16 = 0
    var gidHigh: UInt16 = 0
    var checksumLow: UInt16 = 0
    var reserved: UInt16 = 0
    var extraIsize: UInt16 = 0
    var checksumHigh: UInt16 = 0
    var ctimeExtra: UInt32 = 0
    var mtimeExtra: UInt32 = 0
    var atimeExtra: UInt32 = 0
    var crtime: UInt32 = 0
    var crtimeExtra: UInt32 = 0
    var versionHigh: UInt32 = 0
    var projid: UInt32 = 0
}

/// On-disk directory entry structure
struct EXT4DirectoryEntry {
    var inode: UInt32 = 0
    var recordLength: UInt16 = 0
    var nameLength: UInt8 = 0
    var fileType: UInt8 = 0
}

/// Extent header structure
struct EXT4ExtentHeader {
    var magic: UInt16 = 0
    var entries: UInt16 = 0
    var max: UInt16 = 0
    var depth: UInt16 = 0
    var generation: UInt32 = 0
}

/// Extent leaf structure
struct EXT4ExtentLeaf {
    var block: UInt32 = 0
    var length: UInt16 = 0
    var startHigh: UInt16 = 0
    var startLow: UInt32 = 0
}


private enum EXT4FileType: UInt8 {
    case unknown = 0
    case regular = 1
    case directory = 2
    case character = 3
    case block = 4
    case fifo = 5
    case socket = 6
    case symbolicLink = 7
}

private enum EXT4ModeFlag: UInt16 {
    case S_IFIFO = 0x1000
    case S_IFCHR = 0x2000
    case S_IFDIR = 0x4000
    case S_IFBLK = 0x6000
    case S_IFREG = 0x8000
    case S_IFLNK = 0xA000
    case S_IFSOCK = 0xC000
    case TypeMask = 0xF000
}


/// Editor for in-place modification of ext4 filesystems
public final class EXT4Editor {
    private let handle: FileHandle
    private let devicePath: String
    private var superBlock: EXT4SuperBlock
    private var groupDescriptors: [EXT4GroupDescriptor] = []

    // Computed properties from superblock
    private var blockSize: UInt32 {
        1024 << superBlock.logBlockSize
    }

    private var groupCount: UInt32 {
        (superBlock.blocksCountLow + superBlock.blocksPerGroup - 1) / superBlock.blocksPerGroup
    }

    private var groupDescriptorSize: Int {
        MemoryLayout<EXT4GroupDescriptor>.size
    }


    /// Open an existing ext4 filesystem for editing
    public init(devicePath: FilePath) throws {
        let path = devicePath.description
        self.devicePath = path

        guard FileManager.default.fileExists(atPath: path) else {
            throw EXT4EditorError.fileNotFound(path)
        }

        do {
            self.handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        } catch {
            throw EXT4EditorError.fileNotFound(path)
        }

        // Read superblock
        self.superBlock = EXT4SuperBlock()
        try handle.seek(toOffset: EXT4Constants.superBlockOffset)
        guard let sbData = try handle.read(upToCount: MemoryLayout<EXT4SuperBlock>.size) else {
            throw EXT4EditorError.readError("Failed to read superblock")
        }
        self.superBlock = sbData.withUnsafeBytes { ptr in
            ptr.load(as: EXT4SuperBlock.self)
        }

        guard superBlock.magic == EXT4Constants.superBlockMagic else {
            throw EXT4EditorError.invalidMagic
        }

        // Read group descriptors
        try loadGroupDescriptors()
    }

    deinit {
        try? handle.close()
    }


    /// Add a file to the filesystem
    /// - Parameters:
    ///   - path: Absolute path where the file should be created
    ///   - data: File contents
    ///   - mode: File permissions (default 0o644)
    ///   - uid: Owner user ID (default 0)
    ///   - gid: Owner group ID (default 0)
    public func addFile(
        path: String,
        data: Data,
        mode: UInt16 = 0o644,
        uid: UInt32 = 0,
        gid: UInt32 = 0
    ) throws {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        // Parse path into parent directory and filename
        let components = normalizedPath.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            throw EXT4EditorError.invalidPath(path)
        }

        let fileName = components.last!
        let parentPath = "/" + components.dropLast().joined(separator: "/")

        // Find parent directory inode
        let parentInodeNum = try resolvePathToInode(parentPath)
        let parentInode = try readInode(number: parentInodeNum)

        // Verify parent is a directory
        guard (parentInode.mode & EXT4ModeFlag.TypeMask.rawValue) == EXT4ModeFlag.S_IFDIR.rawValue else {
            throw EXT4EditorError.parentNotDirectory(parentPath)
        }

        // Check if file already exists
        let existingEntries = try readDirectoryEntries(inodeNum: parentInodeNum)
        if existingEntries.contains(where: { $0.name == fileName }) {
            throw EXT4EditorError.fileAlreadyExists(normalizedPath)
        }

        // Allocate blocks for file data
        let blocksNeeded = (UInt32(data.count) + blockSize - 1) / blockSize
        let allocatedBlocks = try allocateBlocks(count: max(1, blocksNeeded))

        // Allocate inode
        let newInodeNum = try allocateInode()

        // Write file data to allocated blocks
        try writeFileData(data: data, blocks: allocatedBlocks)

        // Create and write the new inode
        var newInode = createFileInode(
            mode: mode,
            uid: uid,
            gid: gid,
            size: UInt64(data.count),
            blocks: allocatedBlocks
        )
        try writeInode(number: newInodeNum, inode: &newInode)

        // Add directory entry to parent
        try addDirectoryEntry(
            parentInodeNum: parentInodeNum,
            childInodeNum: newInodeNum,
            childName: fileName,
            fileType: .regular
        )

        // Update superblock
        try updateSuperBlockAfterAllocation(blocksUsed: UInt32(allocatedBlocks.count), inodesUsed: 1)
    }

    /// Add a symbolic link to the filesystem
    public func addSymlink(
        path: String,
        target: String,
        uid: UInt32 = 0,
        gid: UInt32 = 0
    ) throws {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        // Parse path
        let components = normalizedPath.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            throw EXT4EditorError.invalidPath(path)
        }

        let linkName = components.last!
        let parentPath = "/" + components.dropLast().joined(separator: "/")

        // Find parent directory
        let parentInodeNum = try resolvePathToInode(parentPath)
        let parentInode = try readInode(number: parentInodeNum)

        guard (parentInode.mode & EXT4ModeFlag.TypeMask.rawValue) == EXT4ModeFlag.S_IFDIR.rawValue else {
            throw EXT4EditorError.parentNotDirectory(parentPath)
        }

        // Check if already exists
        let existingEntries = try readDirectoryEntries(inodeNum: parentInodeNum)
        if existingEntries.contains(where: { $0.name == linkName }) {
            throw EXT4EditorError.fileAlreadyExists(normalizedPath)
        }

        // Allocate inode
        let newInodeNum = try allocateInode()

        // Create symlink inode
        var newInode = createSymlinkInode(target: target, uid: uid, gid: gid)

        // For short symlinks (< 60 bytes), target is stored in inode block field
        // For longer symlinks, we'd need to allocate blocks
        if target.utf8.count >= 60 {
            let targetData = Data(target.utf8)
            let allocatedBlocks = try allocateBlocks(count: 1)
            try writeFileData(data: targetData, blocks: allocatedBlocks)
            newInode = createSymlinkInodeWithBlocks(target: target, uid: uid, gid: gid, blocks: allocatedBlocks)
            try updateSuperBlockAfterAllocation(blocksUsed: 1, inodesUsed: 1)
        } else {
            try updateSuperBlockAfterAllocation(blocksUsed: 0, inodesUsed: 1)
        }

        try writeInode(number: newInodeNum, inode: &newInode)

        // Add directory entry
        try addDirectoryEntry(
            parentInodeNum: parentInodeNum,
            childInodeNum: newInodeNum,
            childName: linkName,
            fileType: .symbolicLink
        )
    }

    /// Create a directory in the filesystem
    public func createDirectory(
        path: String,
        mode: UInt16 = 0o755,
        uid: UInt32 = 0,
        gid: UInt32 = 0
    ) throws {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        // Parse path
        let components = normalizedPath.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            throw EXT4EditorError.invalidPath(path)
        }

        let dirName = components.last!
        let parentPath = components.count == 1 ? "/" : "/" + components.dropLast().joined(separator: "/")

        // Find parent directory
        let parentInodeNum = try resolvePathToInode(parentPath)
        var parentInode = try readInode(number: parentInodeNum)

        guard (parentInode.mode & EXT4ModeFlag.TypeMask.rawValue) == EXT4ModeFlag.S_IFDIR.rawValue else {
            throw EXT4EditorError.parentNotDirectory(parentPath)
        }

        // Check if already exists
        let existingEntries = try readDirectoryEntries(inodeNum: parentInodeNum)
        if existingEntries.contains(where: { $0.name == dirName }) {
            throw EXT4EditorError.fileAlreadyExists(normalizedPath)
        }

        // Allocate block for directory entries
        let dirBlocks = try allocateBlocks(count: 1)

        // Allocate inode
        let newInodeNum = try allocateInode()

        // Create directory inode
        var newInode = createDirectoryInode(
            mode: mode,
            uid: uid,
            gid: gid,
            blocks: dirBlocks,
            parentInodeNum: parentInodeNum
        )
        try writeInode(number: newInodeNum, inode: &newInode)

        // Write initial directory entries (. and ..)
        try writeInitialDirectoryEntries(
            dirInodeNum: newInodeNum,
            parentInodeNum: parentInodeNum,
            block: dirBlocks[0]
        )

        // Add directory entry to parent
        try addDirectoryEntry(
            parentInodeNum: parentInodeNum,
            childInodeNum: newInodeNum,
            childName: dirName,
            fileType: .directory
        )

        // Update parent's link count
        parentInode.linksCount += 1
        try writeInode(number: parentInodeNum, inode: &parentInode)

        // Update superblock
        try updateSuperBlockAfterAllocation(blocksUsed: 1, inodesUsed: 1)
    }

    /// Check if a path exists in the filesystem
    public func exists(path: String) -> Bool {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return (try? resolvePathToInode(normalizedPath)) != nil
    }

    /// Sync changes to disk
    public func sync() throws {
        try handle.synchronize()
    }


    private func loadGroupDescriptors() throws {
        let gdOffset = UInt64(blockSize)  // Group descriptors start after first block
        try handle.seek(toOffset: gdOffset)

        groupDescriptors = []
        for _ in 0..<groupCount {
            guard let gdData = try handle.read(upToCount: groupDescriptorSize) else {
                throw EXT4EditorError.readError("Failed to read group descriptor")
            }
            let gd = gdData.withUnsafeBytes { ptr in
                ptr.load(as: EXT4GroupDescriptor.self)
            }
            groupDescriptors.append(gd)
        }
    }

    private func readInode(number: UInt32) throws -> EXT4Inode {
        let group = (number - 1) / superBlock.inodesPerGroup
        let indexInGroup = (number - 1) % superBlock.inodesPerGroup

        guard Int(group) < groupDescriptors.count else {
            throw EXT4EditorError.readError("Invalid inode group")
        }

        let gd = groupDescriptors[Int(group)]
        let inodeTableOffset = UInt64(gd.inodeTableLow) * UInt64(blockSize)
        let inodeOffset = inodeTableOffset + UInt64(indexInGroup) * UInt64(EXT4Constants.inodeSize)

        try handle.seek(toOffset: inodeOffset)
        guard let inodeData = try handle.read(upToCount: MemoryLayout<EXT4Inode>.size) else {
            throw EXT4EditorError.readError("Failed to read inode \(number)")
        }

        return inodeData.withUnsafeBytes { ptr in
            ptr.load(as: EXT4Inode.self)
        }
    }

    private func writeInode(number: UInt32, inode: inout EXT4Inode) throws {
        let group = (number - 1) / superBlock.inodesPerGroup
        let indexInGroup = (number - 1) % superBlock.inodesPerGroup

        guard Int(group) < groupDescriptors.count else {
            throw EXT4EditorError.writeError("Invalid inode group")
        }

        let gd = groupDescriptors[Int(group)]
        let inodeTableOffset = UInt64(gd.inodeTableLow) * UInt64(blockSize)
        let inodeOffset = inodeTableOffset + UInt64(indexInGroup) * UInt64(EXT4Constants.inodeSize)

        try handle.seek(toOffset: inodeOffset)
        let data = withUnsafeBytes(of: &inode) { Data($0) }
        try handle.write(contentsOf: data)

        // Pad to full inode size
        let padding = Data(repeating: 0, count: Int(EXT4Constants.inodeSize) - MemoryLayout<EXT4Inode>.size)
        try handle.write(contentsOf: padding)
    }

    private func resolvePathToInode(_ path: String) throws -> UInt32 {
        if path == "/" || path.isEmpty {
            return EXT4Constants.rootInode
        }

        var currentInode = EXT4Constants.rootInode
        let components = path.split(separator: "/").map(String.init)

        for component in components {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                // For simplicity, we don't fully support .. navigation
                // In a real implementation, we'd track parent inodes
                continue
            }

            let entries = try readDirectoryEntries(inodeNum: currentInode)
            guard let entry = entries.first(where: { $0.name == component }) else {
                throw EXT4EditorError.parentNotFound(path)
            }
            currentInode = entry.inode
        }

        return currentInode
    }

    private func readDirectoryEntries(inodeNum: UInt32) throws -> [(name: String, inode: UInt32, fileType: UInt8)] {
        let inode = try readInode(number: inodeNum)

        // Get extent information from inode
        let extents = try getExtents(from: inode)
        var entries: [(name: String, inode: UInt32, fileType: UInt8)] = []

        for (startBlock, endBlock) in extents {
            for blockNum in startBlock..<endBlock {
                let blockOffset = UInt64(blockNum) * UInt64(blockSize)
                try handle.seek(toOffset: blockOffset)
                guard let blockData = try handle.read(upToCount: Int(blockSize)) else {
                    continue
                }

                var offset = 0
                while offset < blockData.count {
                    let entryData = blockData.subdata(in: offset..<min(offset + MemoryLayout<EXT4DirectoryEntry>.size, blockData.count))
                    guard entryData.count >= MemoryLayout<EXT4DirectoryEntry>.size else { break }

                    let entry = entryData.withUnsafeBytes { ptr in
                        ptr.load(as: EXT4DirectoryEntry.self)
                    }

                    if entry.inode == 0 || entry.recordLength == 0 {
                        break
                    }

                    let nameStart = offset + MemoryLayout<EXT4DirectoryEntry>.size
                    let nameEnd = nameStart + Int(entry.nameLength)
                    if nameEnd <= blockData.count {
                        let nameData = blockData.subdata(in: nameStart..<nameEnd)
                        if let name = String(data: nameData, encoding: .utf8) {
                            entries.append((name: name, inode: entry.inode, fileType: entry.fileType))
                        }
                    }

                    offset += Int(entry.recordLength)
                }
            }
        }

        return entries
    }

    private func getExtents(from inode: EXT4Inode) throws -> [(start: UInt32, end: UInt32)] {
        let blockData = withUnsafeBytes(of: inode.block) { Data($0) }
        var extents: [(start: UInt32, end: UInt32)] = []

        // Read extent header
        let header = blockData.withUnsafeBytes { ptr in
            ptr.load(as: EXT4ExtentHeader.self)
        }

        guard header.magic == EXT4Constants.extentHeaderMagic else {
            return []
        }

        let headerSize = MemoryLayout<EXT4ExtentHeader>.size
        let leafSize = MemoryLayout<EXT4ExtentLeaf>.size

        if header.depth == 0 {
            // Direct extents
            for i in 0..<Int(header.entries) {
                let leafOffset = headerSize + i * leafSize
                guard leafOffset + leafSize <= blockData.count else { break }

                let leaf = blockData.subdata(in: leafOffset..<leafOffset + leafSize).withUnsafeBytes { ptr in
                    ptr.load(as: EXT4ExtentLeaf.self)
                }
                extents.append((start: leaf.startLow, end: leaf.startLow + UInt32(leaf.length)))
            }
        }
        // For depth > 0, we'd need to follow extent index nodes (not implemented for MVP)

        return extents
    }

    private func allocateBlocks(count: UInt32) throws -> [UInt32] {
        var allocated: [UInt32] = []
        var remaining = count

        for groupIndex in 0..<Int(groupCount) {
            if remaining == 0 { break }

            let gd = groupDescriptors[groupIndex]
            if gd.freeBlocksCountLow == 0 { continue }

            // Read block bitmap
            let bitmapOffset = UInt64(gd.blockBitmapLow) * UInt64(blockSize)
            try handle.seek(toOffset: bitmapOffset)
            guard var bitmapData = try handle.read(upToCount: Int(blockSize)) else {
                continue
            }

            // Find free blocks in this group
            let blocksInGroup = superBlock.blocksPerGroup
            for blockIndex in 0..<blocksInGroup {
                if remaining == 0 { break }

                let byteIndex = Int(blockIndex / 8)
                let bitIndex = Int(blockIndex % 8)

                if byteIndex < bitmapData.count {
                    if (bitmapData[byteIndex] & (1 << bitIndex)) == 0 {
                        // Block is free, allocate it
                        bitmapData[byteIndex] |= (1 << bitIndex)
                        let absoluteBlock = UInt32(groupIndex) * blocksInGroup + blockIndex
                        allocated.append(absoluteBlock)
                        remaining -= 1

                        // Update group descriptor
                        groupDescriptors[groupIndex].freeBlocksCountLow -= 1
                    }
                }
            }

            // Write updated bitmap
            try handle.seek(toOffset: bitmapOffset)
            try handle.write(contentsOf: bitmapData)

            // Write updated group descriptor
            try writeGroupDescriptor(index: groupIndex)
        }

        guard remaining == 0 else {
            throw EXT4EditorError.noFreeBlocks
        }

        return allocated
    }

    private func allocateInode() throws -> UInt32 {
        for groupIndex in 0..<Int(groupCount) {
            let gd = groupDescriptors[groupIndex]
            if gd.freeInodesCountLow == 0 { continue }

            // Read inode bitmap
            let bitmapOffset = UInt64(gd.inodeBitmapLow) * UInt64(blockSize)
            try handle.seek(toOffset: bitmapOffset)
            guard var bitmapData = try handle.read(upToCount: Int(blockSize)) else {
                continue
            }

            // Find free inode in this group
            let inodesInGroup = superBlock.inodesPerGroup
            for inodeIndex in 0..<inodesInGroup {
                let byteIndex = Int(inodeIndex / 8)
                let bitIndex = Int(inodeIndex % 8)

                if byteIndex < bitmapData.count {
                    if (bitmapData[byteIndex] & (1 << bitIndex)) == 0 {
                        // Inode is free, allocate it
                        bitmapData[byteIndex] |= (1 << bitIndex)
                        let absoluteInode = UInt32(groupIndex) * inodesInGroup + inodeIndex + 1

                        // Skip reserved inodes
                        if absoluteInode < EXT4Constants.firstInode {
                            continue
                        }

                        // Write updated bitmap
                        try handle.seek(toOffset: bitmapOffset)
                        try handle.write(contentsOf: bitmapData)

                        // Update group descriptor
                        groupDescriptors[groupIndex].freeInodesCountLow -= 1
                        try writeGroupDescriptor(index: groupIndex)

                        return absoluteInode
                    }
                }
            }
        }

        throw EXT4EditorError.noFreeInodes
    }

    private func writeGroupDescriptor(index: Int) throws {
        let gdOffset = UInt64(blockSize) + UInt64(index * groupDescriptorSize)
        try handle.seek(toOffset: gdOffset)
        var gd = groupDescriptors[index]
        let data = withUnsafeBytes(of: &gd) { Data($0) }
        try handle.write(contentsOf: data)
    }

    private func writeFileData(data: Data, blocks: [UInt32]) throws {
        var offset = 0
        for block in blocks {
            let blockOffset = UInt64(block) * UInt64(blockSize)
            try handle.seek(toOffset: blockOffset)

            let remaining = data.count - offset
            let bytesToWrite = min(remaining, Int(blockSize))

            if bytesToWrite > 0 {
                let chunk = data.subdata(in: offset..<offset + bytesToWrite)
                try handle.write(contentsOf: chunk)

                // Pad to block size if needed
                if bytesToWrite < Int(blockSize) {
                    let padding = Data(repeating: 0, count: Int(blockSize) - bytesToWrite)
                    try handle.write(contentsOf: padding)
                }
            } else {
                // Write empty block
                let zeros = Data(repeating: 0, count: Int(blockSize))
                try handle.write(contentsOf: zeros)
            }

            offset += bytesToWrite
        }
    }

    private func createFileInode(
        mode: UInt16,
        uid: UInt32,
        gid: UInt32,
        size: UInt64,
        blocks: [UInt32]
    ) -> EXT4Inode {
        var inode = EXT4Inode()
        inode.mode = EXT4ModeFlag.S_IFREG.rawValue | mode
        inode.uid = UInt16(uid & 0xFFFF)
        inode.uidHigh = UInt16((uid >> 16) & 0xFFFF)
        inode.gid = UInt16(gid & 0xFFFF)
        inode.gidHigh = UInt16((gid >> 16) & 0xFFFF)
        inode.sizeLow = UInt32(size & 0xFFFFFFFF)
        inode.sizeHigh = UInt32((size >> 32) & 0xFFFFFFFF)
        inode.linksCount = 1
        inode.flags = 0x80000  // EXT4_EXTENTS_FL

        let now = UInt32(Date().timeIntervalSince1970)
        inode.atime = now
        inode.ctime = now
        inode.mtime = now
        inode.crtime = now
        inode.extraIsize = 32

        // Create extent header and leaf in inode block field
        inode.block = createExtentBlock(blocks: blocks)
        inode.blocksLow = UInt32(blocks.count) * (blockSize / 512)  // In 512-byte sectors

        return inode
    }

    private func createSymlinkInode(target: String, uid: UInt32, gid: UInt32) -> EXT4Inode {
        var inode = EXT4Inode()
        inode.mode = EXT4ModeFlag.S_IFLNK.rawValue | 0o777
        inode.uid = UInt16(uid & 0xFFFF)
        inode.uidHigh = UInt16((uid >> 16) & 0xFFFF)
        inode.gid = UInt16(gid & 0xFFFF)
        inode.gidHigh = UInt16((gid >> 16) & 0xFFFF)
        inode.sizeLow = UInt32(target.utf8.count)
        inode.linksCount = 1

        let now = UInt32(Date().timeIntervalSince1970)
        inode.atime = now
        inode.ctime = now
        inode.mtime = now
        inode.crtime = now
        inode.extraIsize = 32

        // Store short symlink target directly in block field
        var blockData: [UInt8] = Array(repeating: 0, count: 60)
        let targetBytes = Array(target.utf8)
        for (i, byte) in targetBytes.prefix(60).enumerated() {
            blockData[i] = byte
        }
        inode.block = tupleFromArray(blockData)

        return inode
    }

    private func createSymlinkInodeWithBlocks(target: String, uid: UInt32, gid: UInt32, blocks: [UInt32]) -> EXT4Inode {
        var inode = EXT4Inode()
        inode.mode = EXT4ModeFlag.S_IFLNK.rawValue | 0o777
        inode.uid = UInt16(uid & 0xFFFF)
        inode.uidHigh = UInt16((uid >> 16) & 0xFFFF)
        inode.gid = UInt16(gid & 0xFFFF)
        inode.gidHigh = UInt16((gid >> 16) & 0xFFFF)
        inode.sizeLow = UInt32(target.utf8.count)
        inode.linksCount = 1
        inode.flags = 0x80000  // EXT4_EXTENTS_FL

        let now = UInt32(Date().timeIntervalSince1970)
        inode.atime = now
        inode.ctime = now
        inode.mtime = now
        inode.crtime = now
        inode.extraIsize = 32

        inode.block = createExtentBlock(blocks: blocks)
        inode.blocksLow = UInt32(blocks.count) * (blockSize / 512)

        return inode
    }

    private func createDirectoryInode(
        mode: UInt16,
        uid: UInt32,
        gid: UInt32,
        blocks: [UInt32],
        parentInodeNum: UInt32
    ) -> EXT4Inode {
        var inode = EXT4Inode()
        inode.mode = EXT4ModeFlag.S_IFDIR.rawValue | mode
        inode.uid = UInt16(uid & 0xFFFF)
        inode.uidHigh = UInt16((uid >> 16) & 0xFFFF)
        inode.gid = UInt16(gid & 0xFFFF)
        inode.gidHigh = UInt16((gid >> 16) & 0xFFFF)
        inode.sizeLow = blockSize
        inode.linksCount = 2  // . and parent's entry
        inode.flags = 0x80000  // EXT4_EXTENTS_FL

        let now = UInt32(Date().timeIntervalSince1970)
        inode.atime = now
        inode.ctime = now
        inode.mtime = now
        inode.crtime = now
        inode.extraIsize = 32

        inode.block = createExtentBlock(blocks: blocks)
        inode.blocksLow = UInt32(blocks.count) * (blockSize / 512)

        return inode
    }

    private func createExtentBlock(blocks: [UInt32]) -> (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) {
        var blockData: [UInt8] = Array(repeating: 0, count: 60)

        guard !blocks.isEmpty else {
            return tupleFromArray(blockData)
        }

        // Create extent header
        var header = EXT4ExtentHeader()
        header.magic = EXT4Constants.extentHeaderMagic
        header.entries = 1
        header.max = 4
        header.depth = 0

        // Write header to blockData
        withUnsafeBytes(of: header) { ptr in
            for (i, byte) in ptr.enumerated() {
                blockData[i] = byte
            }
        }

        // Create extent leaf (assuming contiguous blocks)
        var leaf = EXT4ExtentLeaf()
        leaf.block = 0
        leaf.length = UInt16(blocks.count)
        leaf.startLow = blocks[0]

        // Write leaf after header
        let headerSize = MemoryLayout<EXT4ExtentHeader>.size
        withUnsafeBytes(of: leaf) { ptr in
            for (i, byte) in ptr.enumerated() {
                blockData[headerSize + i] = byte
            }
        }

        return tupleFromArray(blockData)
    }

    private func addDirectoryEntry(
        parentInodeNum: UInt32,
        childInodeNum: UInt32,
        childName: String,
        fileType: EXT4FileType
    ) throws {
        let parentInode = try readInode(number: parentInodeNum)
        let extents = try getExtents(from: parentInode)

        guard let lastExtent = extents.last, lastExtent.end > lastExtent.start else {
            throw EXT4EditorError.directoryFull("Parent directory has no blocks")
        }

        // Read the last block of the directory
        let lastBlock = lastExtent.end - 1
        let blockOffset = UInt64(lastBlock) * UInt64(blockSize)
        try handle.seek(toOffset: blockOffset)
        guard var blockData = try handle.read(upToCount: Int(blockSize)) else {
            throw EXT4EditorError.readError("Failed to read directory block")
        }

        // Parse all directory entries to find the last REAL entry (with inode != 0)
        // and any sentinel entry (inode == 0) or free space at the end
        var offset = 0
        var lastRealEntryOffset = -1
        var lastRealEntryRecordLen: UInt16 = 0
        var lastRealEntryNameLen: UInt8 = 0
        var sentinelOffset = -1
        var sentinelRecordLen: UInt16 = 0

        while offset < Int(blockSize) {
            guard offset + MemoryLayout<EXT4DirectoryEntry>.size <= blockData.count else { break }

            let entryData = blockData.subdata(in: offset..<offset + MemoryLayout<EXT4DirectoryEntry>.size)
            let entry = entryData.withUnsafeBytes { ptr in
                ptr.load(as: EXT4DirectoryEntry.self)
            }

            if entry.recordLength == 0 {
                // No more entries
                break
            }

            if entry.inode == 0 {
                // This is a sentinel/free entry - we can use this space
                sentinelOffset = offset
                sentinelRecordLen = entry.recordLength
                break
            }

            // This is a real entry
            lastRealEntryOffset = offset
            lastRealEntryRecordLen = entry.recordLength
            lastRealEntryNameLen = entry.nameLength
            offset += Int(entry.recordLength)
        }

        // Calculate space needed for new entry
        let nameBytes = Array(childName.utf8)
        let newEntryMinSize = MemoryLayout<EXT4DirectoryEntry>.size + nameBytes.count
        let newEntryAlignedSize = (newEntryMinSize + 3) & ~3

        var newEntryOffset: Int
        var newRecordLen: UInt16

        if sentinelOffset >= 0 {
            // There's a sentinel entry - check if we can fit in its space
            if Int(sentinelRecordLen) >= newEntryAlignedSize {
                newEntryOffset = sentinelOffset
                newRecordLen = sentinelRecordLen
            } else {
                throw EXT4EditorError.directoryFull("No space in directory block for new entry")
            }
        } else if lastRealEntryOffset >= 0 {
            // No sentinel - check if we can split the last real entry's record
            let lastEntryActualSize = (MemoryLayout<EXT4DirectoryEntry>.size + Int(lastRealEntryNameLen) + 3) & ~3
            let availableSpace = Int(lastRealEntryRecordLen) - lastEntryActualSize

            if availableSpace >= newEntryAlignedSize {
                // Shrink last entry's record length to its actual size
                let updatedRecordLen = UInt16(lastEntryActualSize)
                blockData[lastRealEntryOffset + 4] = UInt8(updatedRecordLen & 0xFF)
                blockData[lastRealEntryOffset + 5] = UInt8((updatedRecordLen >> 8) & 0xFF)

                newEntryOffset = lastRealEntryOffset + lastEntryActualSize
                newRecordLen = UInt16(Int(blockSize) - newEntryOffset)
            } else {
                throw EXT4EditorError.directoryFull("No space in directory block for new entry")
            }
        } else {
            // Empty directory block (shouldn't happen for valid directories)
            newEntryOffset = 0
            newRecordLen = UInt16(blockSize)
        }

        // Create new directory entry
        var newEntry = EXT4DirectoryEntry()
        newEntry.inode = childInodeNum
        newEntry.recordLength = newRecordLen
        newEntry.nameLength = UInt8(nameBytes.count)
        newEntry.fileType = fileType.rawValue

        // Write new entry header
        withUnsafeBytes(of: newEntry) { ptr in
            for (i, byte) in ptr.enumerated() {
                blockData[newEntryOffset + i] = byte
            }
        }

        // Write name
        for (i, byte) in nameBytes.enumerated() {
            blockData[newEntryOffset + MemoryLayout<EXT4DirectoryEntry>.size + i] = byte
        }

        // Zero out remaining bytes of the entry (padding)
        let entryEnd = newEntryOffset + newEntryAlignedSize
        for i in (newEntryOffset + MemoryLayout<EXT4DirectoryEntry>.size + nameBytes.count)..<entryEnd {
            if i < blockData.count {
                blockData[i] = 0
            }
        }

        // Write updated block
        try handle.seek(toOffset: blockOffset)
        try handle.write(contentsOf: blockData)
    }

    private func writeInitialDirectoryEntries(
        dirInodeNum: UInt32,
        parentInodeNum: UInt32,
        block: UInt32
    ) throws {
        var blockData = Data(repeating: 0, count: Int(blockSize))

        // Write "." entry
        var dotEntry = EXT4DirectoryEntry()
        dotEntry.inode = dirInodeNum
        dotEntry.recordLength = 12
        dotEntry.nameLength = 1
        dotEntry.fileType = EXT4FileType.directory.rawValue

        withUnsafeBytes(of: dotEntry) { ptr in
            for (i, byte) in ptr.enumerated() {
                blockData[i] = byte
            }
        }
        blockData[MemoryLayout<EXT4DirectoryEntry>.size] = 0x2E  // '.'

        // Write ".." entry
        var dotDotEntry = EXT4DirectoryEntry()
        dotDotEntry.inode = parentInodeNum
        dotDotEntry.recordLength = UInt16(blockSize - 12)
        dotDotEntry.nameLength = 2
        dotDotEntry.fileType = EXT4FileType.directory.rawValue

        let dotDotOffset = 12
        withUnsafeBytes(of: dotDotEntry) { ptr in
            for (i, byte) in ptr.enumerated() {
                blockData[dotDotOffset + i] = byte
            }
        }
        blockData[dotDotOffset + MemoryLayout<EXT4DirectoryEntry>.size] = 0x2E  // '.'
        blockData[dotDotOffset + MemoryLayout<EXT4DirectoryEntry>.size + 1] = 0x2E  // '.'

        // Write block
        let blockOffset = UInt64(block) * UInt64(blockSize)
        try handle.seek(toOffset: blockOffset)
        try handle.write(contentsOf: blockData)
    }

    private func updateSuperBlockAfterAllocation(blocksUsed: UInt32, inodesUsed: UInt32) throws {
        superBlock.freeBlocksCountLow -= blocksUsed
        superBlock.freeInodesCount -= inodesUsed

        try handle.seek(toOffset: EXT4Constants.superBlockOffset)
        var sb = superBlock
        let data = withUnsafeBytes(of: &sb) { Data($0) }
        try handle.write(contentsOf: data)
    }

    // Helper to convert array to tuple
    private func tupleFromArray(_ arr: [UInt8]) -> (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) {
        (
            arr[0], arr[1], arr[2], arr[3], arr[4], arr[5], arr[6], arr[7], arr[8], arr[9],
            arr[10], arr[11], arr[12], arr[13], arr[14], arr[15], arr[16], arr[17], arr[18], arr[19],
            arr[20], arr[21], arr[22], arr[23], arr[24], arr[25], arr[26], arr[27], arr[28], arr[29],
            arr[30], arr[31], arr[32], arr[33], arr[34], arr[35], arr[36], arr[37], arr[38], arr[39],
            arr[40], arr[41], arr[42], arr[43], arr[44], arr[45], arr[46], arr[47], arr[48], arr[49],
            arr[50], arr[51], arr[52], arr[53], arr[54], arr[55], arr[56], arr[57], arr[58], arr[59]
        )
    }
}
