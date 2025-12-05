import Foundation
import Libarchive

enum LibArchiveError: Error {
    case invalidPath
    case archiveCreationFailed(String)
    case archiveReadFailed(String)
    case archiveWriteFailed(String)
    case entryReadFailed(String)
}

private let AE_IFMT: UInt32 = 0o170000
private let AE_IFREG: UInt32 = 0o100000
private let AE_IFLNK: UInt32 = 0o120000
private let AE_IFDIR: UInt32 = 0o040000
private let AE_IFIFO: UInt32 = 0o010000

struct LibArchiveUtility {

    static func extract(tarPath: URL, to destination: URL) throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: tarPath.path) else {
            throw LibArchiveError.invalidPath
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        guard let archive = archive_read_new() else {
            throw LibArchiveError.archiveCreationFailed("Failed to create archive reader")
        }
        defer { archive_read_free(archive) }

        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)

        let result = tarPath.path.withCString { path in
            archive_read_open_filename(archive, path, 10240)
        }

        guard result == ARCHIVE_OK else {
            let errorMsg = String(cString: archive_error_string(archive))
            throw LibArchiveError.archiveReadFailed(errorMsg)
        }

        var entry: OpaquePointer?
        var entryCount = 0
        var headerResult: Int32

        while true {
            headerResult = archive_read_next_header(archive, &entry)

            if headerResult == ARCHIVE_EOF {
                break
            }

            if headerResult != ARCHIVE_OK {
                let errorMsg = String(cString: archive_error_string(archive))
                throw LibArchiveError.archiveReadFailed("Failed to read header for entry \(entryCount): \(errorMsg)")
            }

            guard let entry = entry else { continue }
            entryCount += 1

            guard let pathname = archive_entry_pathname(entry) else {
                continue
            }

            let pathString = String(cString: pathname)
            let outputPath = destination.appendingPathComponent(pathString)

            let entryType = UInt32(archive_entry_filetype(entry))

            if entryType & AE_IFDIR != 0 {
                try fileManager.createDirectory(at: outputPath, withIntermediateDirectories: true)
            } else {
                let parentDir = outputPath.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parentDir.path) {
                    try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }

                if entryType & AE_IFREG != 0 {
                    let expectedSize = archive_entry_size(entry)
                    fileManager.createFile(atPath: outputPath.path, contents: nil)
                    guard let fileHandle = try? FileHandle(forWritingTo: outputPath) else {
                        throw LibArchiveError.archiveWriteFailed("Failed to open file for writing: \(outputPath.path)")
                    }
                    defer { try? fileHandle.close() }

                    var buffer = [UInt8](repeating: 0, count: 8192)
                    var bytesRead: Int
                    var totalBytesRead: Int64 = 0

                    repeat {
                        bytesRead = archive_read_data(archive, &buffer, buffer.count)
                        if bytesRead > 0 {
                            let data = Data(bytes: buffer, count: bytesRead)
                            fileHandle.write(data)
                            totalBytesRead += Int64(bytesRead)
                        } else if bytesRead < 0 {
                            let errorMsg = String(cString: archive_error_string(archive))
                            throw LibArchiveError.entryReadFailed("Failed reading '\(pathString)' at offset \(totalBytesRead)/\(expectedSize): \(errorMsg)")
                        }
                    } while bytesRead > 0

                    let mode = archive_entry_mode(entry)
                    try? fileManager.setAttributes([.posixPermissions: mode & 0o777], ofItemAtPath: outputPath.path)
                } else if entryType & AE_IFLNK != 0 {
                    if let linkTarget = archive_entry_symlink(entry) {
                        let linkTargetString = String(cString: linkTarget)
                        try? fileManager.createSymbolicLink(
                            atPath: outputPath.path,
                            withDestinationPath: linkTargetString
                        )
                    }
                }
            }
        }
    }

    static func create(tarPath: URL, from source: URL) throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: source.path) else {
            throw LibArchiveError.invalidPath
        }

        guard let archive = archive_write_new() else {
            throw LibArchiveError.archiveCreationFailed("Failed to create archive writer")
        }
        defer { archive_write_free(archive) }

        archive_write_set_format_pax_restricted(archive)
        archive_write_add_filter_none(archive)

        let openResult = tarPath.path.withCString { path in
            archive_write_open_filename(archive, path)
        }

        guard openResult == ARCHIVE_OK else {
            let errorMsg = String(cString: archive_error_string(archive))
            throw LibArchiveError.archiveWriteFailed(errorMsg)
        }

        let enumerator = fileManager.enumerator(atPath: source.path)
        var files: [(path: String, url: URL)] = []

        while let relativePath = enumerator?.nextObject() as? String {
            let fullURL = source.appendingPathComponent(relativePath)
            files.append((path: relativePath, url: fullURL))
        }

        for (relativePath, fullURL) in files {
            let attributes = try fileManager.attributesOfItem(atPath: fullURL.path)
            let fileType = attributes[.type] as? FileAttributeType

            guard let entry = archive_entry_new() else { continue }
            defer { archive_entry_free(entry) }

            relativePath.withCString { path in
                archive_entry_set_pathname(entry, path)
            }

            if fileType == .typeDirectory {
                archive_entry_set_filetype(entry, AE_IFDIR)
                archive_entry_set_perm(entry, 0o755)
                archive_entry_set_size(entry, 0)
            } else if fileType == .typeSymbolicLink {
                let linkDestination = try fileManager.destinationOfSymbolicLink(atPath: fullURL.path)
                archive_entry_set_filetype(entry, AE_IFLNK)
                linkDestination.withCString { dest in
                    archive_entry_set_symlink(entry, dest)
                }
                archive_entry_set_size(entry, 0)
            } else if fileType == .typeRegular {
                let fileSize = (attributes[.size] as? UInt64) ?? 0
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.int32Value ?? 0o644

                archive_entry_set_filetype(entry, AE_IFREG)
                archive_entry_set_perm(entry, mode_t(permissions))
                archive_entry_set_size(entry, Int64(fileSize))
            } else {
                continue
            }

            if let modificationDate = attributes[.modificationDate] as? Date {
                let timestamp = Int(modificationDate.timeIntervalSince1970)
                archive_entry_set_mtime(entry, timestamp, 0)
            }

            let writeHeaderResult = archive_write_header(archive, entry)
            guard writeHeaderResult == ARCHIVE_OK else {
                let errorMsg = String(cString: archive_error_string(archive))
                throw LibArchiveError.archiveWriteFailed(errorMsg)
            }

            if fileType == .typeRegular {
                guard let fileHandle = try? FileHandle(forReadingFrom: fullURL) else {
                    throw LibArchiveError.archiveReadFailed("Failed to open file for reading: \(fullURL.path)")
                }
                defer { try? fileHandle.close() }

                let bufferSize = 8192
                while true {
                    let data = fileHandle.readData(ofLength: bufferSize)
                    if data.isEmpty { break }

                    let written = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                        archive_write_data(archive, ptr.baseAddress, data.count)
                    }

                    if written < 0 {
                        let errorMsg = String(cString: archive_error_string(archive))
                        throw LibArchiveError.archiveWriteFailed(errorMsg)
                    }
                }
            }
        }

        archive_write_close(archive)
    }
}
