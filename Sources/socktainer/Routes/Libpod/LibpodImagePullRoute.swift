import ContainerAPIClient
import ContainerPersistence
import ContainerizationError
import Foundation
import Vapor

struct LibpodImagePullRoute: RouteCollection {
    let client: ClientImageProtocol
    let systemConfig: ContainerSystemConfig

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/images/pull", use: LibpodImagePullRoute.handler(client: client, systemConfig: systemConfig))
    }

    static func handler(client: ClientImageProtocol, systemConfig: ContainerSystemConfig) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let reference = req.query["reference"] as String?, !reference.isEmpty else {
                throw Abort(.badRequest, reason: "Missing reference query parameter")
            }
            let platformString: String? = req.query["platform"]

            let (image, tag) = parseReference(reference)

            // `podman create`/`run` pull with `policy=missing`: an image already in the store must
            // not be fetched again (and `never` must not fetch at all). `always`/`newer` pull.
            let policy = (req.query["policy"] as String?) ?? "always"
            if policy == "missing" || policy == "never" {
                let present: Bool
                do {
                    _ = try await ClientImage.get(reference: reference.removingPercentEncoding ?? reference, containerSystemConfig: systemConfig)
                    present = true
                } catch let error as ContainerizationError where error.code == .notFound {
                    present = false
                }
                if present {
                    let ref = reference.removingPercentEncoding ?? reference
                    let line = "{\"images\":[\(jsonString(ref))],\"id\":\(jsonString(ref))}\n"
                    let response = Response(status: .ok, body: .init(string: line))
                    response.headers.contentType = .json
                    return response
                }
                if policy == "never" {
                    throw Abort(.notFound, reason: "image not known: \(reference)")
                }
            }

            let platform = try requestedPlatform(
                platform: platformString,
                os: req.query["os"] ?? req.query["OS"],
                arch: req.query["arch"] ?? req.query["Arch"],
                variant: req.query["variant"] ?? req.query["Variant"])

            let response = Response()
            response.headers.add(name: .contentType, value: "application/json")
            let progressStream = try await client.pull(
                image: image, tag: tag, platform: platform, logger: req.logger)

            struct PullStreamLine: Encodable {
                var stream: String?
                var images: [String]?
                var id: String?
                var error: String?
            }
            let encoder = JSONEncoder()
            @Sendable func encodeLine(_ line: PullStreamLine) -> ByteBuffer {
                guard let data = try? encoder.encode(line) else {
                    return ByteBuffer(string: "{\"error\": \"failed to encode progress\"}\n")
                }
                var buffer = ByteBuffer(bytes: data)
                buffer.writeString("\n")
                return buffer
            }

            response.body = .init(stream: { writer in
                Task {
                    do {
                        for try await progress in progressStream {
                            let message: String
                            switch progress {
                            case .message(let text): message = text
                            case .downloading(let current, let total): message = "Downloading \(current)/\(total)"
                            case .extracting(let current, let total): message = "Extracting \(current)/\(total)"
                            }
                            _ = writer.write(.buffer(encodeLine(PullStreamLine(stream: message + "\n"))))
                        }
                        let imageRef = tag.isEmpty ? image : "\(image):\(tag)"
                        _ = writer.write(.buffer(encodeLine(PullStreamLine(images: [imageRef], id: imageRef))))
                        _ = writer.write(.end)
                    } catch {
                        // The error frame is the failure report; end the stream cleanly after it
                        // (as Docker-compat's pull does) so podman reads it instead of a broken body.
                        _ = writer.write(.buffer(encodeLine(PullStreamLine(error: BuildRoute.errorMessage(for: error)))))
                        _ = writer.write(.end)
                    }
                }
            })
            return response
        }
    }

    /// `podman pull --platform os/arch[/variant]` (like `--os`/`--arch`/`--variant`) sends separate
    /// `os`, `arch` and `variant` query parameters, not Docker's `platform`; a part left out
    /// defaults to the host's, as on podman. A `platform` parameter still takes precedence.
    static func requestedPlatform(platform: String?, os: String?, arch: String?, variant: String?) throws -> Platform {
        if let platform, !platform.isEmpty {
            do {
                return try platformOrThrow(platform)
            } catch {
                throw Abort(.badRequest, reason: "Failed to parse platform '\(platform)': \(error.localizedDescription)")
            }
        }
        let os = os.flatMap { $0.isEmpty ? nil : $0 }
        let arch = arch.flatMap { $0.isEmpty ? nil : $0 }
        let variant = variant.flatMap { $0.isEmpty ? nil : $0 }
        guard os != nil || arch != nil || variant != nil else {
            return currentPlatform()
        }
        let host = currentPlatform()
        let spec = ["\(os ?? host.os)/\(arch ?? host.architecture)", variant].compactMap { $0 }.joined(separator: "/")
        do {
            return try Platform(from: spec)
        } catch {
            throw Abort(.badRequest, reason: "Failed to parse platform '\(spec)': \(error.localizedDescription)")
        }
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }

    private static func parseReference(_ reference: String) -> (image: String, tag: String) {
        let decoded = reference.removingPercentEncoding ?? reference
        // A digest reference (name@sha256:...) has no tag component — the colon inside
        // the digest is not a tag separator.
        if decoded.contains("@") {
            return (decoded, "")
        }
        if let colonIndex = decoded.lastIndex(of: ":"),
            !decoded[colonIndex...].contains("/")
        {
            let image = String(decoded[..<colonIndex])
            let tag = String(decoded[decoded.index(after: colonIndex)...])
            return (image, tag)
        }
        return (decoded, "")
    }
}
