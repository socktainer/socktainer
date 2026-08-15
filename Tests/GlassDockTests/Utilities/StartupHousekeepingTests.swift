import Foundation
import Testing

@testable import GlassDock

@Suite("Startup housekeeping deadline")
struct StartupHousekeepingTests {

    @Test("work that finishes in time returns true")
    func finishesInTime() async {
        let finished = await StartupHousekeeping.runBounded(timeout: .seconds(5)) {
            // completes immediately
        }
        #expect(finished == true)
    }

    @Test("work that outlives the deadline is abandoned and returns false")
    func abandonedAtDeadline() async {
        let finished = await StartupHousekeeping.runBounded(timeout: .milliseconds(50)) {
            // Simulates an XPC await that never resolves and ignores
            // cancellation — sleep is cancellable, but nothing cancels the
            // abandoned task, so it stands in for a stuck continuation.
            try? await Task.sleep(for: .seconds(600))
        }
        #expect(finished == false)
    }

    @Test("work finishing after the deadline does not double-resume")
    func lateFinishIsHarmless() async throws {
        let finished = await StartupHousekeeping.runBounded(timeout: .milliseconds(20)) {
            try? await Task.sleep(for: .milliseconds(60))
        }
        #expect(finished == false)
        // Give the late worker time to complete its claim() after the timeout
        // already resumed — a double-resume would crash the process here.
        try await Task.sleep(for: .milliseconds(120))
    }

    @Test("slow-but-in-time work still returns true")
    func slowWorkWithinDeadline() async {
        let finished = await StartupHousekeeping.runBounded(timeout: .seconds(5)) {
            try? await Task.sleep(for: .milliseconds(30))
        }
        #expect(finished == true)
    }
}
