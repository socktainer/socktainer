import Foundation
import Testing

@testable import socktainer

@Suite("PushDestinationGate")
struct PushDestinationGateTests {
    @Test("a second acquire on the same destination waits for the first release")
    func serializesSameDestination() async throws {
        let gate = PushDestinationGate(pollInterval: .milliseconds(5))
        let first = await gate.acquire("registry/img:tag")

        let order = Order()
        let waiter = Task {
            let token = await gate.acquire("registry/img:tag")
            await order.record("second")
            await gate.release("registry/img:tag", token: token)
        }
        try await Task.sleep(for: .milliseconds(60))
        await order.record("first-releasing")
        await gate.release("registry/img:tag", token: first)
        await waiter.value
        #expect(await order.events == ["first-releasing", "second"])
    }

    @Test("different destinations do not block each other")
    func independentDestinations() async {
        let gate = PushDestinationGate(pollInterval: .milliseconds(5))
        let a = await gate.acquire("a")
        let b = await gate.acquire("b")
        await gate.release("a", token: a)
        await gate.release("b", token: b)
    }

    @Test("an expired lease no longer blocks, and its stale holder cannot release the new one")
    func expiredLease() async throws {
        // Long enough that `fresh` stays valid through the checks below, so a waiter that gets in
        // can only have been let in by the stale release.
        let gate = PushDestinationGate(leaseDuration: 0.5, pollInterval: .milliseconds(5))
        let stale = await gate.acquire("d")
        try await Task.sleep(for: .milliseconds(600))
        let fresh = await gate.acquire("d")  // would hang if the expired lease still blocked
        await gate.release("d", token: stale)  // stale token: must not free `fresh`

        let order = Order()
        let third = Task {
            let token = await gate.acquire("d")
            await order.record("third")
            await gate.release("d", token: token)
        }
        try await Task.sleep(for: .milliseconds(50))
        await order.record("fresh-releasing")
        await gate.release("d", token: fresh)
        await third.value
        #expect(await order.events == ["fresh-releasing", "third"])
    }
}

private actor Order {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}
