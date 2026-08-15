import Darwin
import Foundation
import Vapor

enum EngineStateLockError: Error, Equatable {
    case alreadyRunning
    case openFailed(errno: Int32)
    case lockFailed(errno: Int32)
}

final class EngineStateLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(directory: URL) throws -> EngineStateLock {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let path = directory.appendingPathComponent("engine.lock").path
        let descriptor = Darwin.open(
            path,
            O_CREAT | O_CLOEXEC | O_RDWR | O_EXLOCK | O_NONBLOCK,
            0o600
        )
        guard descriptor >= 0 else {
            if errno == EWOULDBLOCK {
                throw EngineStateLockError.alreadyRunning
            }
            throw EngineStateLockError.openFailed(errno: errno)
        }
        return EngineStateLock(descriptor: descriptor)
    }

    deinit {
        Darwin.close(descriptor)
    }
}

struct EngineStateLockKey: StorageKey {
    typealias Value = EngineStateLock
}
