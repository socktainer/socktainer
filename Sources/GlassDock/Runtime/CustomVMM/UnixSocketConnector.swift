import Darwin
import Foundation

protocol RuntimeMachineSocketConnecting: Sendable {
    func connect(to url: URL) throws -> FileHandle
}

struct DarwinRuntimeMachineSocketConnector: RuntimeMachineSocketConnecting {
    func connect(to url: URL) throws -> FileHandle {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RuntimeMachineError.socketConnect(path: url.path, errno: errno)
        }
        do {
            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(url.path.utf8)
            let capacity = withUnsafeBytes(of: address.sun_path) { $0.count }
            guard pathBytes.count < capacity else {
                throw RuntimeMachineError.invalidConfiguration(
                    "VMM socket path exceeds \(capacity - 1) bytes"
                )
            }
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.initializeMemory(as: UInt8.self, repeating: 0)
                destination.copyBytes(from: pathBytes)
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                throw RuntimeMachineError.socketConnect(path: url.path, errno: errno)
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}
