import Darwin
import Foundation

enum BoundedFileReadError: Error, Equatable, LocalizedError {
    case invalidRelativePath(String)
    case cannotOpen(String)
    case notRegularFile(String)
    case exceedsLimit(path: String, maxBytes: Int)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let path):
            return "metadata path is not a safe relative path: \(path)"
        case .cannotOpen(let path):
            return "metadata file is missing or unreadable: \(path)"
        case .notRegularFile(let path):
            return "metadata path is not a regular file: \(path)"
        case .exceedsLimit(let path, let maxBytes):
            return "metadata file \(path) exceeds the \(maxBytes)-byte limit"
        case .readFailed(let path):
            return "failed to read metadata file: \(path)"
        }
    }
}

/// Descriptor-anchored, no-follow reads for archive-controlled metadata.
/// Bounding the outer tar is insufficient: OCI index, manifest, and config
/// JSON would otherwise be materialized into memory up to the archive's much
/// larger payload ceiling before decoding. A 16-MiB document is already far
/// above registry-scale image metadata while keeping JSON allocation and
/// descriptor fanout deterministic.
enum BoundedFileReader {
    static let maxImageMetadataBytes = 16 * 1024 * 1024

    static func readImageMetadata(
        relativePath: String,
        under root: URL
    ) throws -> Data {
        try read(
            relativePath: relativePath,
            under: root,
            maxBytes: maxImageMetadataBytes
        )
    }

    static func read(
        relativePath: String,
        under root: URL,
        maxBytes: Int
    ) throws -> Data {
        guard maxBytes >= 0,
            !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            !relativePath.utf8.contains(0)
        else {
            throw BoundedFileReadError.invalidRelativePath(relativePath)
        }

        var components: [String] = []
        for component in relativePath.split(
            separator: "/",
            omittingEmptySubsequences: true
        ) {
            if component == "." { continue }
            guard component != ".." else {
                throw BoundedFileReadError.invalidRelativePath(relativePath)
            }
            components.append(String(component))
        }
        guard !components.isEmpty else {
            throw BoundedFileReadError.invalidRelativePath(relativePath)
        }

        var fileDescriptor = open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fileDescriptor >= 0 else {
            throw BoundedFileReadError.cannotOpen(relativePath)
        }
        defer { close(fileDescriptor) }

        for (index, component) in components.enumerated() {
            let isFinal = index == components.count - 1
            let flags =
                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
                | (isFinal ? 0 : O_DIRECTORY)
            let nextDescriptor = openat(
                fileDescriptor,
                component,
                flags
            )
            guard nextDescriptor >= 0 else {
                throw BoundedFileReadError.cannotOpen(relativePath)
            }
            close(fileDescriptor)
            fileDescriptor = nextDescriptor
        }

        var status = stat()
        guard fstat(fileDescriptor, &status) == 0 else {
            throw BoundedFileReadError.readFailed(relativePath)
        }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else {
            throw BoundedFileReadError.notRegularFile(relativePath)
        }
        guard status.st_size <= Int64(maxBytes) else {
            throw BoundedFileReadError.exceedsLimit(
                path: relativePath,
                maxBytes: maxBytes
            )
        }

        var result = Data()
        result.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let bytesRead = buffer.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
            }
            if bytesRead < 0, errno == EINTR { continue }
            guard bytesRead >= 0 else {
                throw BoundedFileReadError.readFailed(relativePath)
            }
            guard bytesRead > 0 else { break }
            guard result.count <= maxBytes - bytesRead else {
                throw BoundedFileReadError.exceedsLimit(
                    path: relativePath,
                    maxBytes: maxBytes
                )
            }
            result.append(contentsOf: buffer.prefix(bytesRead))
        }
        return result
    }
}
