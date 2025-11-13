import Foundation

enum TarError: Error {
    case invalidPath
    case invalidHeader
}

struct TarUtility {

    static func extract(tarPath: URL, to destination: URL) throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: tarPath.path) else {
            throw TarError.invalidPath
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let fileHandle = try FileHandle(forReadingFrom: tarPath)
        defer { try? fileHandle.close() }

        var offset: UInt64 = 0

        while true {
            try fileHandle.seek(toOffset: offset)
            let headerData = fileHandle.readData(ofLength: 512)

            if headerData.count < 512 {
                break
            }

            if headerData.allSatisfy({ $0 == 0 }) {
                break
            }

            guard let header = try? parseTarHeader(headerData) else {
                break
            }

            offset += 512

            let filePath = destination.appendingPathComponent(header.name)

            if header.typeFlag == .directory {
                try fileManager.createDirectory(at: filePath, withIntermediateDirectories: true)
            } else if header.typeFlag == .regular || header.typeFlag == .normalFile {
                if let parentDir = filePath.deletingLastPathComponent().path.isEmpty ? nil : filePath.deletingLastPathComponent() {
                    try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }

                try fileHandle.seek(toOffset: offset)
                let fileData = fileHandle.readData(ofLength: Int(header.size))
                try fileData.write(to: filePath)
            } else if header.typeFlag == .symlink || header.typeFlag == .hardlink {
                let linkTarget = destination.appendingPathComponent(header.linkname)
                if fileManager.fileExists(atPath: linkTarget.path) {
                    if header.typeFlag == .symlink {
                        try? fileManager.createSymbolicLink(at: filePath, withDestinationURL: linkTarget)
                    } else {
                        try? fileManager.linkItem(at: linkTarget, to: filePath)
                    }
                }
            }

            let paddedSize = ((header.size + 511) / 512) * 512
            offset += paddedSize
        }
    }

    static func create(tarPath: URL, from source: URL) throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: source.path) else {
            throw TarError.invalidPath
        }

        fileManager.createFile(atPath: tarPath.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tarPath)
        defer { try? fileHandle.close() }

        let enumerator = fileManager.enumerator(atPath: source.path)
        var files: [(path: String, url: URL)] = []

        while let relativePath = enumerator?.nextObject() as? String {
            let fullURL = source.appendingPathComponent(relativePath)
            files.append((path: relativePath, url: fullURL))
        }

        for (relativePath, fullURL) in files {
            let attributes = try fileManager.attributesOfItem(atPath: fullURL.path)
            let fileType = attributes[.type] as? FileAttributeType
            let fileSize = (attributes[.size] as? UInt64) ?? 0
            let modificationDate = (attributes[.modificationDate] as? Date) ?? Date()
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint64Value ?? 0o644

            var header = TarHeader(
                name: relativePath,
                mode: permissions,
                uid: 0,
                gid: 0,
                size: fileSize,
                mtime: UInt64(modificationDate.timeIntervalSince1970),
                typeFlag: .regular,
                linkname: "",
                magic: "ustar",
                version: "00",
                uname: "",
                gname: ""
            )

            if fileType == .typeDirectory {
                header.typeFlag = .directory
                header.size = 0
                header.mode = 0o755
            } else if fileType == .typeSymbolicLink {
                header.typeFlag = .symlink
                let linkDestination = try fileManager.destinationOfSymbolicLink(atPath: fullURL.path)
                header.linkname = linkDestination
                header.size = 0
            }

            let headerData = try createTarHeader(header)
            fileHandle.write(headerData)

            if fileType == .typeRegular {
                let fileData = try Data(contentsOf: fullURL)
                fileHandle.write(fileData)

                let padding = (512 - (fileData.count % 512)) % 512
                if padding > 0 {
                    fileHandle.write(Data(count: padding))
                }
            }
        }

        fileHandle.write(Data(count: 1024))
    }

    private static func parseTarHeader(_ data: Data) throws -> TarHeader {
        guard data.count == 512 else {
            throw TarError.invalidHeader
        }

        func readString(at offset: Int, length: Int) -> String {
            let range = offset..<min(offset + length, data.count)
            let bytes = data[range]
            if let nullIndex = bytes.firstIndex(of: 0) {
                return String(data: Data(bytes[..<nullIndex]), encoding: .utf8) ?? ""
            }
            return String(data: Data(bytes), encoding: .utf8) ?? ""
        }

        func readOctal(at offset: Int, length: Int) -> UInt64 {
            let str = readString(at: offset, length: length).trimmingCharacters(in: .whitespaces)
            return UInt64(str, radix: 8) ?? 0
        }

        let name = readString(at: 0, length: 100)
        let mode = readOctal(at: 100, length: 8)
        let uid = readOctal(at: 108, length: 8)
        let gid = readOctal(at: 116, length: 8)
        let size = readOctal(at: 124, length: 12)
        let mtime = readOctal(at: 136, length: 12)
        let typeFlagByte = data[156]
        let linkname = readString(at: 157, length: 100)
        let magic = readString(at: 257, length: 6)
        let version = readString(at: 263, length: 2)
        let uname = readString(at: 265, length: 32)
        let gname = readString(at: 297, length: 32)

        let typeFlag = TarTypeFlag(rawValue: typeFlagByte) ?? .regular

        return TarHeader(
            name: name,
            mode: mode,
            uid: uid,
            gid: gid,
            size: size,
            mtime: mtime,
            typeFlag: typeFlag,
            linkname: linkname,
            magic: magic,
            version: version,
            uname: uname,
            gname: gname
        )
    }

    private static func createTarHeader(_ header: TarHeader) throws -> Data {
        var data = Data(count: 512)

        func writeString(_ str: String, at offset: Int, length: Int) {
            let bytes = [UInt8](str.utf8)
            let writeLength = min(bytes.count, length)
            data.replaceSubrange(offset..<(offset + writeLength), with: bytes[..<writeLength])
        }

        func writeOctal(_ value: UInt64, at offset: Int, length: Int) {
            let octalStr = String(value, radix: 8)
            let paddedStr = String(repeating: "0", count: max(0, length - octalStr.count - 1)) + octalStr
            writeString(paddedStr, at: offset, length: length - 1)
        }

        writeString(header.name, at: 0, length: 100)
        writeOctal(header.mode, at: 100, length: 8)
        writeOctal(header.uid, at: 108, length: 8)
        writeOctal(header.gid, at: 116, length: 8)
        writeOctal(header.size, at: 124, length: 12)
        writeOctal(header.mtime, at: 136, length: 12)

        data[148] = 32
        data[149] = 32
        data[150] = 32
        data[151] = 32
        data[152] = 32
        data[153] = 32
        data[154] = 32
        data[155] = 32

        data[156] = header.typeFlag.rawValue
        writeString(header.linkname, at: 157, length: 100)
        writeString(header.magic, at: 257, length: 6)
        writeString(header.version, at: 263, length: 2)
        writeString(header.uname, at: 265, length: 32)
        writeString(header.gname, at: 297, length: 32)

        var checksum: UInt64 = 0
        for byte in data {
            checksum += UInt64(byte)
        }

        let checksumStr = String(checksum, radix: 8)
        let paddedChecksum = String(repeating: "0", count: max(0, 6 - checksumStr.count)) + checksumStr
        writeString(paddedChecksum, at: 148, length: 6)
        data[154] = 0
        data[155] = 32

        return data
    }
}

enum TarTypeFlag: UInt8 {
    case regular = 0
    case normalFile = 48
    case hardlink = 49
    case symlink = 50
    case charDevice = 51
    case blockDevice = 52
    case directory = 53
    case fifo = 54
}

struct TarHeader {
    let name: String
    var mode: UInt64
    let uid: UInt64
    let gid: UInt64
    var size: UInt64
    let mtime: UInt64
    var typeFlag: TarTypeFlag
    var linkname: String
    let magic: String
    let version: String
    let uname: String
    let gname: String
}
