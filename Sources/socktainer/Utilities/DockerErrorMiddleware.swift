import Foundation
import Vapor

/// Docker clients expect API error bodies shaped like Moby's: `{"message": "..."}`.
/// Vapor's default `AbortError` rendering uses `{"error": true, "reason": "..."}`,
/// which has no `message` key. The docker-py SDK's
/// `create_api_error_from_http_exception` does `response.json()['message']` and only
/// guards `ValueError` (non-JSON) — a missing `message` key raises
/// `KeyError('message')`. That masks the real HTTP error: e.g. a clean 404
/// `ImageNotFound` (which callers catch to trigger an image pull) surfaces instead as
/// `KeyError('message')` and escapes the `except ImageNotFound` handler. MiniStack's
/// Lambda docker-executor hits exactly this on first use of an RIE base image
/// ("spawn error: 'message'"), so no Lambda can cold-start.
///
/// This middleware is installed outermost (at `.beginning`) and makes every error
/// response Docker-compatible by ensuring a `message` field is present, preserving
/// the original `error`/`reason` fields for any existing consumers.
struct DockerErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            let response = try await next.respond(to: request)
            // A downstream error middleware may already have rendered the error as a
            // Response. Ensure error-status JSON bodies carry a `message` field.
            if response.status.code >= 400 {
                return Self.ensureMessageField(in: response)
            }
            return response
        } catch is CancellationError {
            // Vapor's default error handling rethrows CancellationError so request
            // cancellation propagates and downstream cleanup runs. This middleware is
            // outermost, so it must preserve that behaviour rather than turn a
            // cancellation into a 500.
            throw CancellationError()
        } catch {
            let status: HTTPResponseStatus
            let reason: String
            if let abort = error as? AbortError {
                status = abort.status
                reason = abort.reason
            } else {
                status = .internalServerError
                reason = String(describing: error)
            }
            request.logger.debug("DockerErrorMiddleware: rendering \(status.code) as Docker error: \(reason)")
            return Self.makeDockerError(status: status, message: reason)
        }
    }

    /// Rewrites an already-rendered error response so its JSON body includes a
    /// `message` field. Non-JSON bodies are wrapped so clients always get
    /// `{"message": ...}`.
    static func ensureMessageField(in response: Response) -> Response {
        guard let bodyData = response.body.data, !bodyData.isEmpty else {
            // An error status with no body still lacks `message` — the exact shape that
            // breaks docker-py. Synthesise a Docker error so `message` is always present.
            return makeDockerError(status: response.status, message: "error", headers: response.headers)
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        else {
            let text = response.body.string ?? "error"
            return makeDockerError(status: response.status, message: text, headers: response.headers)
        }
        if json["message"] != nil {
            return response  // already Docker-compatible
        }
        let message = (json["reason"] as? String) ?? "error"
        var merged = json
        merged["message"] = message
        let newResponse = Response(status: response.status)
        newResponse.headers = response.headers
        if let data = try? JSONSerialization.data(withJSONObject: merged) {
            newResponse.headers.replaceOrAdd(name: .contentType, value: "application/json")
            newResponse.body = .init(data: data)
        }
        return newResponse
    }

    static func makeDockerError(
        status: HTTPResponseStatus,
        message: String,
        headers: HTTPHeaders = HTTPHeaders()
    ) -> Response {
        let response = Response(status: status)
        response.headers = headers
        response.headers.replaceOrAdd(name: .contentType, value: "application/json")
        let payload: [String: Any] = ["message": message, "error": true, "reason": message]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            response.body = .init(data: data)
        } else {
            response.body = .init(string: "{\"message\":\"\(message)\"}")
        }
        return response
    }
}
