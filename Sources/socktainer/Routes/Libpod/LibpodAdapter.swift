import Foundation
import NIOCore
import Vapor

/// The libpod API reuses Docker-compat's route semantics, but not its wire shapes: the real
/// podman client decodes `/libpod/*` responses into its own types (a prune call returns an array
/// of reports, a wait returns a bare integer, and so on) and sends some parameters under
/// different names. Adapters here run the Docker-compat handler and translate in both directions
/// so each libpod route stays a thin wrapper instead of a second implementation.
enum LibpodAdapter {
    typealias Handler = @Sendable (Request) async throws -> Response

    static func jsonResponse(_ value: Any, status: HTTPStatus = .ok) throws -> Response {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        let response = Response(status: status, body: .init(data: data))
        response.headers.contentType = .json
        return response
    }

    /// The decoded JSON body of `response` (collecting it first when streamed), or nil when it has none.
    static func jsonBody(of response: Response, on req: Request) async -> Any? {
        var collected = response.body.buffer
        if collected == nil {
            do {
                collected = try await response.body.collect(on: req.eventLoop).get()
            } catch {
                req.logger.error("LibpodAdapter: collecting a streamed body failed: \(error)")
            }
        }
        guard let buffer = collected, buffer.readableBytes > 0 else {
            req.logger.debug("LibpodAdapter: empty body (status \(response.status.code))")
            return nil
        }
        do {
            return try JSONSerialization.jsonObject(with: Data(buffer: buffer), options: [.fragmentsAllowed])
        } catch {
            req.logger.error("LibpodAdapter: body is not JSON (\(buffer.readableBytes) bytes): \(error)")
            return nil
        }
    }

    /// Runs the Docker-compat handler and, if it succeeds, answers with `transform` of its JSON
    /// body (nil when the handler returned none). Non-2xx responses pass through untouched.
    static func reshaping<T: AsyncResponseEncodable>(
        _ docker: @escaping @Sendable (Request) async throws -> T,
        status: HTTPStatus = .ok,
        prepare: @escaping @Sendable (Request) async throws -> Request = { $0 },
        _ transform: @escaping @Sendable (Any?, Request) async throws -> Any
    ) -> Handler {
        { req in
            let prepared = try await prepare(req)
            let response = try await docker(prepared).encodeResponse(for: req)
            guard (200..<300).contains(Int(response.status.code)) else { return response }
            return try await jsonResponse(transform(await jsonBody(of: response, on: req), req), status: status)
        }
    }

    /// Runs `prepare` (to rewrite the request into what the Docker-compat handler expects)
    /// before delegating; the response is returned unchanged. `prepare` mutates the request in
    /// place, or returns a replacement when the body has to change.
    static func preparing<T>(
        _ docker: @escaping @Sendable (Request) async throws -> T, _ prepare: @escaping @Sendable (Request) async throws -> Request
    ) -> @Sendable (Request) async throws -> T {
        { req in
            try await docker(prepare(req))
        }
    }

    /// Sets (replacing any existing value) a query parameter on the request URL.
    static func setQuery(_ req: Request, _ name: String, to value: String) {
        var components = URLComponents(string: req.url.string) ?? URLComponents()
        var items = components.queryItems ?? []
        items.removeAll { $0.name == name }
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        req.url = URI(string: components.string ?? req.url.string)
    }

    /// Podman sends several parameters under its own name (`timeout` where Docker says `t`). Copies
    /// the libpod value to the name the Docker-compat handler reads, unless that one is already set.
    static func aliasQuery(_ req: Request, libpod: String, docker: String) {
        guard req.query[String.self, at: docker] == nil, let value = req.query[String.self, at: libpod] else { return }
        setQuery(req, docker, to: value)
    }

    /// The podman client sends JSON bodies without a `Content-Type`; Vapor's content decoding
    /// refuses those, so default to JSON when none was given.
    static func defaultToJSON(_ req: Request) {
        if req.headers.contentType == nil {
            req.headers.contentType = .json
        }
    }

    /// The request body decoded as a JSON object (empty when there is none).
    static func jsonObjectBody(of req: Request) async throws -> [String: Any] {
        guard let buffer = try await req.body.collect(max: 1 << 20).get(), buffer.readableBytes > 0 else { return [:] }
        // A malformed body is the client's error (400), not a server failure: `NSError` from
        // `JSONSerialization` is no `AbortError`, so it would otherwise render as a 500.
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(buffer: buffer))
        } catch {
            throw Abort(.badRequest, reason: "request body is not valid JSON")
        }
        guard let object = parsed as? [String: Any] else {
            throw Abort(.badRequest, reason: "request body must be a JSON object")
        }
        return object
    }

    /// A copy of `req` whose body is `object` as JSON. Vapor offers no way to swap the body of an
    /// existing request, so this builds a new one carrying over the route parameters.
    static func replacingBody(of req: Request, with object: Any) throws -> Request {
        let data = try JSONSerialization.data(withJSONObject: object)
        var headers = req.headers
        headers.contentType = .json
        headers.replaceOrAdd(name: .contentLength, value: String(data.count))
        let copy = Request(
            application: req.application, method: req.method, url: req.url, version: req.version, headers: headers,
            collectedBody: ByteBuffer(data: data), remoteAddress: req.remoteAddress, logger: req.logger, on: req.eventLoop)
        copy.parameters = req.parameters
        return copy
    }

    /// The libpod routes report a network's id as a hash of its name (`LibpodSchema.networkID`),
    /// which the backend does not know. Resolves a full or abbreviated such id to the network's
    /// name; any other reference (a name, a backend id) is returned unchanged.
    static func resolveNetworkReference(_ reference: String, client: ClientNetworkProtocol, logger: Logger) async throws -> String {
        guard !reference.isEmpty, reference.allSatisfy(\.isHexDigit), try await client.getNetwork(id: reference, logger: logger) == nil else {
            return reference
        }
        let lowered = reference.lowercased()
        let matches = try await client.list(filters: nil, logger: logger).map(\.Name).filter { LibpodSchema.networkID($0).hasPrefix(lowered) }
        return matches.count == 1 ? matches[0] : reference
    }

    /// Rewrites the route parameter `name` from a libpod network id to the network's name.
    static func resolvingNetworkParameter(_ name: String, client: ClientNetworkProtocol) -> @Sendable (Request) async throws -> Request {
        { req in
            if let reference = req.parameters.get(name) {
                req.parameters.set(name, to: try await resolveNetworkReference(reference, client: client, logger: req.logger))
            }
            return req
        }
    }

    /// A body-less copy of `req` addressed to the Docker-compat handler for one resource, with
    /// the route parameter `name` set — for a libpod call that fans out to several of them.
    static func subrequest(of req: Request, parameter name: String, value: String) -> Request {
        let copy = Request(
            application: req.application, method: req.method, url: req.url, version: req.version, headers: req.headers,
            collectedBody: nil, remoteAddress: req.remoteAddress, logger: req.logger, on: req.eventLoop)
        copy.parameters = req.parameters
        copy.parameters.set(name, to: value)
        return copy
    }
}
