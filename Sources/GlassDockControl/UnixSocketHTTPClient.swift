import Darwin
import Foundation

struct HTTPResult: Sendable, Equatable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

struct UnixSocketHTTPClient: Sendable {
    let socketPath: String
    var timeout: TimeInterval = 3
    var maximumResponseBytes = 4 * 1024 * 1024

    func request(method: String, path: String) throws -> HTTPResult {
        guard !socketPath.isEmpty, socketPath.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else {
            throw ControlError.invalidSocketPath(socketPath)
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError("socket") }
        defer { Darwin.close(descriptor) }

        var socketTimeout = timeval(
            tv_sec: Int(timeout.rounded(.down)),
            tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1) * 1_000_000).rounded())
        )
        _ = withUnsafePointer(to: &socketTimeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &socketTimeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            socketPath.utf8.withContiguousStorageIfAvailable { source in
                destination.copyBytes(from: source)
            }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + socketPath.utf8.count + 1)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard connected == 0 else { throw socketError("connect") }

        let request = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        try writeAll(Data(request.utf8), to: descriptor)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                response.append(buffer, count: count)
                guard response.count <= maximumResponseBytes else {
                    throw ControlError.malformedResponse(
                        "response exceeds the \(maximumResponseBytes)-byte limit"
                    )
                }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw socketError("read")
            }
        }
        return try Self.parse(response)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw socketError("write")
                }
            }
        }
    }

    private func socketError(_ operation: String) -> ControlError {
        let message = String(cString: strerror(errno))
        return .socket("\(operation) failed: \(message)")
    }

    static func parse(_ data: Data) throws -> HTTPResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
            let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
        else {
            throw ControlError.malformedResponse("missing HTTP headers")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw ControlError.malformedResponse("missing status line")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw ControlError.malformedResponse("invalid status line")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let rawBody = Data(data[headerRange.upperBound...])
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunked(rawBody)
        } else if let lengthText = headers["content-length"], let length = Int(lengthText) {
            guard rawBody.count >= length else {
                throw ControlError.malformedResponse("truncated response body")
            }
            body = rawBody.prefix(length)
        } else {
            body = rawBody
        }
        return HTTPResult(status: status, headers: headers, body: body)
    }

    private static func decodeChunked(_ data: Data) throws -> Data {
        var cursor = data.startIndex
        var decoded = Data()
        while cursor < data.endIndex {
            guard let lineEnd = data[cursor...].range(of: Data("\r\n".utf8)),
                let sizeText = String(data: data[cursor..<lineEnd.lowerBound], encoding: .utf8),
                let size = Int(sizeText.split(separator: ";", maxSplits: 1)[0], radix: 16)
            else {
                throw ControlError.malformedResponse("invalid chunk header")
            }
            cursor = lineEnd.upperBound
            if size == 0 { return decoded }
            guard data.distance(from: cursor, to: data.endIndex) >= size + 2 else {
                throw ControlError.malformedResponse("truncated chunk")
            }
            let chunkEnd = data.index(cursor, offsetBy: size)
            decoded.append(data[cursor..<chunkEnd])
            cursor = data.index(chunkEnd, offsetBy: 2)
        }
        throw ControlError.malformedResponse("missing final chunk")
    }
}
