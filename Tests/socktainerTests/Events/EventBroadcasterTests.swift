import Foundation
import Testing

@testable import socktainer

@Suite("EventBroadcaster — delivery")
struct EventBroadcasterTests {

    /// An event broadcast immediately after `stream()` must be delivered. The previous
    /// implementation registered the continuation in a deferred `Task`, leaving a window
    /// where a broadcast was dropped for a just-connected listener (the root cause of
    /// missed start/destroy events for fast container lifecycles).
    @Test("event broadcast immediately after stream() is delivered (no registration race)")
    func noRegistrationRace() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        // Broadcast with no yield/sleep between stream() and broadcast(): with the old
        // async registration the continuation was not yet live and this event was lost.
        await broadcaster.broadcast(
            DockerEvent.simpleEvent(id: "race-ctr", type: "container", status: "start"))

        let captureTask = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "start" { return event }
            return nil
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            captureTask.cancel()
        }
        let event = await captureTask.value
        timeout.cancel()

        #expect(event?.id == "race-ctr")
        #expect(event?.Action == "start")
    }

    /// A rapid burst of events (e.g. create→start→die→destroy in microseconds) is all
    /// delivered in order — the unbounded stream buffer must not drop under load.
    @Test("a rapid burst of events is delivered in full and in order")
    func rapidBurstDelivered() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        let actions = ["create", "start", "die", "destroy"]
        for action in actions {
            await broadcaster.broadcast(
                DockerEvent.simpleEvent(id: "burst-ctr", type: "container", status: action))
        }

        let collectTask = Task<[String], Never> {
            var seen: [String] = []
            for await event in stream {
                seen.append(event.Action)
                if seen.count == actions.count { break }
            }
            return seen
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            collectTask.cancel()
        }
        let seen = await collectTask.value
        timeout.cancel()

        #expect(seen == actions, "all burst events delivered in order, got \(seen)")
    }
}
