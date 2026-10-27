import Foundation
import Testing

@testable import socktainer

@Suite("PushDestinationGate")
struct PushDestinationGateTests {
    @Test("a second acquire on the same destination waits for the first release")
    func serializesSameDestination() async throws {
        let gate = PushDestinationGate(pollInterval: .milliseconds(5))
        let first = try await gate.acquire("registry/img:tag")

        let order = Order()
        let waiter = Task {
            let token = try await gate.acquire("registry/img:tag")
            await order.record("second")
            await gate.release("registry/img:tag", token: token)
        }
        try await Task.sleep(for: .milliseconds(60))
        await order.record("first-releasing")
        await gate.release("registry/img:tag", token: first)
        try await waiter.value
        #expect(await order.events == ["first-releasing", "second"])
    }

    @Test("different destinations do not block each other")
    func independentDestinations() async throws {
        let gate = PushDestinationGate(pollInterval: .milliseconds(5))
        let a = try await gate.acquire("a")
        let b = try await gate.acquire("b")
        await gate.release("a", token: a)
        await gate.release("b", token: b)
    }

    @Test("an expired lease no longer blocks, and its stale holder cannot release the new one")
    func expiredLease() async throws {
        // Long enough that `fresh` stays valid through the checks below, so a waiter that gets in
        // can only have been let in by the stale release.
        let gate = PushDestinationGate(leaseDuration: 0.5, pollInterval: .milliseconds(5))
        let stale = try await gate.acquire("d")
        try await Task.sleep(for: .milliseconds(600))
        let fresh = try await gate.acquire("d")  // would hang if the expired lease still blocked
        await gate.release("d", token: stale)  // stale token: must not free `fresh`

        let order = Order()
        let third = Task {
            let token = try await gate.acquire("d")
            await order.record("third")
            await gate.release("d", token: token)
        }
        try await Task.sleep(for: .milliseconds(50))
        await order.record("fresh-releasing")
        await gate.release("d", token: fresh)
        try await third.value
        #expect(await order.events == ["fresh-releasing", "third"])
    }

    @Test("a waiter cancelled while the destination is held stops waiting and takes no lease", .timeLimit(.minutes(1)))
    func cancelledWaiterStopsWaiting() async throws {
        let gate = PushDestinationGate(pollInterval: .milliseconds(5))
        let holder = try await gate.acquire("c")

        let waiter = Task { try await gate.acquire("c") }
        try await Task.sleep(for: .milliseconds(30))
        waiter.cancel()
        // A waiter that discarded the CancellationError kept looping until the holder released,
        // which never happens before this point.
        await #expect(throws: CancellationError.self) { try await waiter.value }

        // The cancelled waiter took no lease: the holder still owns the destination.
        let order = Order()
        let next = Task {
            let token = try await gate.acquire("c")
            await order.record("next")
            await gate.release("c", token: token)
        }
        try await Task.sleep(for: .milliseconds(30))
        await order.record("holder-releasing")
        await gate.release("c", token: holder)
        try await next.value
        #expect(await order.events == ["holder-releasing", "next"])
    }
}

private actor Order {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}
