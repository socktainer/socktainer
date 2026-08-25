import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum SingleInstanceError: Error, CustomStringConvertible, Equatable {
    case missingHomeDirectory
    case alreadyRunning(pid: Int32?, lockPath: String)
    case lockFailed(String)

    public var description: String {
        switch self {
        case .missingHomeDirectory:
            return "Cannot determine home directory to acquire the socktainer instance lock"
        case .alreadyRunning(let pid, let lockPath):
            if let pid {
                return "socktainer is already running (pid \(pid)). Stop it before starting a new instance. (lock: \(lockPath))"
            }
            return "socktainer is already running. Stop it before starting a new instance. (lock: \(lockPath))"
        case .lockFailed(let message):
            return "Failed to acquire socktainer instance lock: \(message)"
        }
    }
}

/// Holds an exclusive advisory lock for as long as this object is alive. The lock is tied to
/// the open file descriptor, so it is released automatically — by the kernel — when the
/// process exits or crashes, even ungracefully. There is no stale-lock cleanup to get wrong.
public final class SingleInstanceLock {
    private let fileDescriptor: Int32

    fileprivate init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        close(fileDescriptor)
    }
}

/// Prevents two socktainer daemons from binding the same Unix socket concurrently.
///
/// Without this, starting a second instance silently unlinks and rebinds the socket out from
/// under a still-running one (see `prepareUnixSocket`): the old process stays alive but
/// orphaned, any client still connected to it keeps talking to a daemon nobody else can
/// reach, and both processes may end up independently managing the same builder VM —
/// which is what produced GRPCCore RPCError(cancelled) failures on cross-arch builds.
///
/// Call this before `prepareUnixSocket` and keep the returned lock alive for the process
/// lifetime (e.g. bind it to a top-level `let` in `main.swift`).
public func acquireSingleInstanceLock(homeDirectory: String?) throws -> SingleInstanceLock {
    guard let homeDirectory, !homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw SingleInstanceError.missingHomeDirectory
    }

    let directory = socketDirectory(homeDirectory: homeDirectory)
    try restrictDirectoryToOwner(at: directory)
    let lockPath = "\(directory)/socktainer.lock"

    let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else {
        throw SingleInstanceError.lockFailed(String(cString: strerror(errno)))
    }

    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        let lockErrno = errno
        if lockErrno == EWOULDBLOCK {
            let existingPID = readPID(fromFD: fd)
            close(fd)
            throw SingleInstanceError.alreadyRunning(pid: existingPID, lockPath: lockPath)
        }
        close(fd)
        throw SingleInstanceError.lockFailed(String(cString: strerror(lockErrno)))
    }

    ftruncate(fd, 0)
    let pidString = "\(ProcessInfo.processInfo.processIdentifier)\n"
    _ = pidString.withCString { write(fd, $0, strlen($0)) }

    return SingleInstanceLock(fileDescriptor: fd)
}

private func readPID(fromFD fd: Int32) -> Int32? {
    lseek(fd, 0, SEEK_SET)
    var buffer = [UInt8](repeating: 0, count: 32)
    let bytesRead = read(fd, &buffer, buffer.count)
    guard bytesRead > 0 else { return nil }
    let text = String(decoding: buffer[0..<bytesRead], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return Int32(text)
}
