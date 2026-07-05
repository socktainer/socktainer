import Foundation
import Testing

@testable import socktainer

private struct SyntheticFailure: Error {}

@Suite("withTimeout")
struct WithTimeoutTests {

    @Test("Returns the operation's result when it completes before the timeout")
    func returnsResultWhenFast() async throws {
        let result = try await withTimeout(nanoseconds: 200_000_000) { 42 }
        #expect(result == 42)
    }

    @Test("Propagates the operation's own error when it fails before the timeout")
    func propagatesOperationError() async {
        await #expect(throws: SyntheticFailure.self) {
            try await withTimeout(nanoseconds: 200_000_000) {
                throw SyntheticFailure()
            }
        }
    }

    @Test("Throws LivenessProbeTimeout when the operation exceeds the timeout")
    func throwsOnTimeout() async {
        await #expect(throws: LivenessProbeTimeout.self) {
            try await withTimeout(nanoseconds: 20_000_000) {
                try? await Task.sleep(nanoseconds: 500_000_000)
                return 1
            }
        }
    }
}
