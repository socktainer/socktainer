import Foundation

/// Polls `condition` until it returns true or `timeoutSeconds` elapses — avoids a fixed
/// sleep in tests that wait on an async background task (e.g. a detached observer).
func pollUntil(timeoutSeconds: Double, _ condition: () async -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() { return true }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}
