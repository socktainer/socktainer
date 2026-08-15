import Foundation
import Vapor

protocol RuntimeReadying: Sendable {
    func waitUntilReady() async throws
}

/// Starts the persistent runtime once and gives every Docker workload request
/// the same in-flight attempt. A later request can retry a failed attempt.
actor RuntimeReadiness: RuntimeReadying {
    private struct Attempt {
        let token: UUID
        let task: Task<Void, Error>
    }

    private let start: @Sendable () async throws -> Void
    private var attempt: Attempt?

    init(start: @escaping @Sendable () async throws -> Void) {
        self.start = start
    }

    func waitUntilReady() async throws {
        let current: Attempt
        if let attempt {
            current = attempt
        } else {
            current = Attempt(token: UUID(), task: Task { try await start() })
            attempt = current
        }
        do {
            try await current.task.value
        } catch {
            if attempt?.token == current.token { attempt = nil }
            throw error
        }
    }

    func cancel() {
        attempt?.task.cancel()
        attempt = nil
    }
}

struct RuntimeReadinessLifecycle: LifecycleHandler {
    let readiness: RuntimeReadiness

    func shutdownAsync(_ application: Application) async {
        await readiness.cancel()
    }
}

/// Keeps the local Docker liveness endpoint available while the persistent
/// runtime completes its independent capability initialization.
struct RuntimeReadinessMiddleware: AsyncMiddleware {
    let readiness: any RuntimeReadying

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if DockerPing.matches(method: request.method, path: request.url.path) {
            return try await next.respond(to: request)
        }
        try await readiness.waitUntilReady()
        return try await next.respond(to: request)
    }
}
