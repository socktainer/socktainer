import Foundation
import Testing

@testable import socktainer

/// Records requested sleeps instead of sleeping, so the backoff can be asserted exactly.
private actor SleepRecorder {
    private(set) var delays: [Duration] = []
    func record(_ delay: Duration) { delays.append(delay) }
}

@Suite("WaitPolling — backoff for container wait")
struct WaitPollingTests {

    @Test("returns without sleeping when the condition already holds")
    func noSleepWhenAlreadyDone() async throws {
        let recorder = SleepRecorder()
        try await WaitPolling.poll(cap: .milliseconds(200), sleep: { await recorder.record($0) }) { true }
        #expect(await recorder.delays.isEmpty)
    }

    @Test("starts at 10ms and doubles up to the cap")
    func backsOffExponentiallyToCap() async throws {
        let recorder = SleepRecorder()
        var checks = 0
        try await WaitPolling.poll(cap: .milliseconds(200), sleep: { await recorder.record($0) }) {
            checks += 1
            return checks == 8
        }
        #expect(
            await recorder.delays == [10, 20, 40, 80, 160, 200, 200].map { Duration.milliseconds($0) })
    }

    @Test("a short-lived container is noticed within the first few polls")
    func firstPollsAreFast() async throws {
        // Before this change, `docker run --rm` waited a fixed 100ms + 200ms after the
        // container was gone. The first three re-checks now happen within 70ms in total.
        let recorder = SleepRecorder()
        var checks = 0
        try await WaitPolling.poll(cap: WaitPolling.removalDelayCap, sleep: { await recorder.record($0) }) {
            checks += 1
            return checks == 4
        }
        let total = await recorder.delays.reduce(Duration.zero, +)
        #expect(total == .milliseconds(70))
    }

    @Test("long waits settle at the previous fixed intervals")
    func capsMatchPreviousIntervals() {
        #expect(WaitPolling.exitDelayCap == .milliseconds(100))
        #expect(WaitPolling.removalDelayCap == .milliseconds(200))
        #expect(WaitPolling.nextDelay(after: .milliseconds(160), cap: .milliseconds(200)) == .milliseconds(200))
        #expect(WaitPolling.nextDelay(after: .milliseconds(200), cap: .milliseconds(200)) == .milliseconds(200))
    }

    @Test("an initial delay above the cap is clamped")
    func clampsInitialDelay() async throws {
        let recorder = SleepRecorder()
        var checks = 0
        try await WaitPolling.poll(initial: .seconds(1), cap: .milliseconds(50), sleep: { await recorder.record($0) }) {
            checks += 1
            return checks == 2
        }
        #expect(await recorder.delays == [.milliseconds(50)])
    }

    @Test("errors from the condition propagate")
    func propagatesErrors() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await WaitPolling.poll(cap: .milliseconds(10), sleep: { _ in }) { throw Boom() }
        }
    }
}
