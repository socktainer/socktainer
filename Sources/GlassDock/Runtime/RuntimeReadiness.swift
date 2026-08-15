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
        Task { [weak self] in
            _ = try? await self?.waitUntilReady()
        }
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
        if Self.isDockerPing(request) {
            return try await next.respond(to: request)
        }
        try await readiness.waitUntilReady()
        return try await next.respond(to: request)
    }

    private static func isDockerPing(_ request: Request) -> Bool {
        guard request.method == .GET || request.method == .HEAD else { return false }
        let components = request.url.path.split(separator: "/")
        guard components.last == "_ping" else { return false }
        if components.count == 1 { return true }
        guard components.count == 2, components[0].first == "v" else { return false }
        let versionParts = components[0].dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        return versionParts.count == 2
            && versionParts.allSatisfy {
                !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber }
            }
    }
}
