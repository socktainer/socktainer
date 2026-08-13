import Foundation

enum GuestFrameKind: String, Codable, Sendable {
    case request
    case response
    case event
    case stream
    case end
    case cancel
}

enum GuestStream: String, Codable, Sendable {
    case stdout
    case stderr
}

struct GuestProtocolError: Codable, Error, Sendable, Equatable {
    let code: String
    let message: String
}

enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let decoded = try? value.decode(Bool.self) {
            self = .bool(decoded)
        } else if let decoded = try? value.decode(Double.self) {
            self = .number(decoded)
        } else if let decoded = try? value.decode(String.self) {
            self = .string(decoded)
        } else if let decoded = try? value.decode([JSONValue].self) {
            self = .array(decoded)
        } else {
            self = .object(try value.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }
}

struct GuestFrame: Codable, Sendable, Equatable {
    static let maximumPayloadSize = 16 * 1024 * 1024

    let id: UInt64
    let kind: GuestFrameKind
    var method: String?
    var payload: JSONValue?
    var stream: GuestStream?
    var data: Data?
    var error: GuestProtocolError?
    var exitCode: Int32?
}

enum GuestFrameCodecError: Error, Equatable {
    case frameTooLarge(Int)
    case truncatedFrame
    case invalidEnvelope(String)
}

struct GuestFrameCodec: Sendable {
    private var buffer = Data()

    static func encode(_ frame: GuestFrame) throws -> Data {
        try validate(frame)
        let payload = try JSONEncoder().encode(frame)
        guard payload.count <= GuestFrame.maximumPayloadSize else {
            throw GuestFrameCodecError.frameTooLarge(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var result = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        result.append(payload)
        return result
    }

    mutating func append(_ bytes: Data) throws -> [GuestFrame] {
        buffer.append(bytes)
        var frames: [GuestFrame] = []
        while buffer.count >= MemoryLayout<UInt32>.size {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0 else {
                throw GuestFrameCodecError.invalidEnvelope("frame length must be nonzero")
            }
            guard length <= GuestFrame.maximumPayloadSize else {
                throw GuestFrameCodecError.frameTooLarge(Int(length))
            }
            let frameSize = 4 + Int(length)
            guard buffer.count >= frameSize else { break }
            let payload = buffer.subdata(in: 4..<frameSize)
            let frame = try JSONDecoder().decode(GuestFrame.self, from: payload)
            try Self.validate(frame)
            frames.append(frame)
            // Rebase Data indices after consuming a frame. Data.removeFirst(_:) can
            // retain a nonzero startIndex, while the wire offsets above are relative.
            buffer = Data(buffer.dropFirst(frameSize))
        }
        return frames
    }

    func finish() throws {
        guard buffer.isEmpty else { throw GuestFrameCodecError.truncatedFrame }
    }

    private static func validate(_ frame: GuestFrame) throws {
        switch frame.kind {
        case .request:
            guard frame.id != 0, frame.method?.isEmpty == false,
                frame.stream == nil, frame.data == nil, frame.error == nil
            else {
                throw GuestFrameCodecError.invalidEnvelope("request requires nonzero id and method")
            }
        case .response:
            guard frame.id != 0 else {
                throw GuestFrameCodecError.invalidEnvelope("response frame requires nonzero id")
            }
            guard frame.stream == nil, frame.data == nil else {
                throw GuestFrameCodecError.invalidEnvelope("response cannot contain stream data")
            }
        case .stream:
            guard frame.id != 0, frame.stream != nil, frame.data != nil,
                frame.error == nil, frame.payload == nil
            else {
                throw GuestFrameCodecError.invalidEnvelope("stream requires id, stream, and data")
            }
        case .end:
            guard frame.id != 0, frame.stream == nil, frame.data == nil else {
                throw GuestFrameCodecError.invalidEnvelope("end requires id without stream data")
            }
        case .cancel:
            guard frame.id != 0, frame.method == nil, frame.payload == nil,
                frame.stream == nil, frame.data == nil, frame.error == nil
            else {
                throw GuestFrameCodecError.invalidEnvelope("cancel requires only a nonzero id")
            }
        case .event:
            guard frame.id == 0, frame.method?.isEmpty == false,
                frame.stream == nil, frame.data == nil, frame.error == nil
            else {
                throw GuestFrameCodecError.invalidEnvelope("event requires id=0 and method")
            }
        }
        if let payload = frame.payload, case .object = payload {
            return
        }
        if frame.payload != nil {
            throw GuestFrameCodecError.invalidEnvelope("payload must be a JSON object")
        }
    }
}
