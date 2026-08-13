import Foundation
import Testing

@testable import socktainer

/// `docker compose up` starts a service by attaching to a stopped container; it never calls
/// `POST /start`. Only the attach route's exit monitor sees that exit, so it must emit `die` —
/// while `docker run`, which goes through both attach and start, must still emit exactly one.
@Suite("DieEventOwnership")
struct DieEventOwnershipTests {
    @Test("only the first claimer owns the die event")
    func singleOwner() async {
        let ownership = DieEventOwnership()

        #expect(await ownership.claim(id: "c1"))
        #expect(await ownership.claim(id: "c1") == false)
    }

    @Test("ownership is reusable after release, so later runs still emit die")
    func releaseAllowsNextRun() async {
        let ownership = DieEventOwnership()

        #expect(await ownership.claim(id: "c1"))
        await ownership.release(id: "c1")
        #expect(await ownership.claim(id: "c1"), "a container's second run must be claimable again")
    }

    @Test("claims are independent per container")
    func independentContainers() async {
        let ownership = DieEventOwnership()

        #expect(await ownership.claim(id: "c1"))
        #expect(await ownership.claim(id: "c2"))
    }
}

@Suite("ContainerProcessExitMonitor die event")
struct ContainerProcessExitMonitorDieTests {
    @Test("emits die with the exit code when nothing else owns the exit")
    func emitsDieWhenUnowned() async {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        await DieEventOwnership.shared.release(id: "monitor-die")

        _ = await ContainerProcessExitMonitor.run(
            wait: { 7 },
            hexId: "abc123",
            nativeId: "monitor-die",
            fallbackImage: "alpine:3.20",
            fallbackLabels: ["com.docker.compose.project": "demo"],
            dnsServer: nil,
            broadcaster: broadcaster,
            outputFlushGraceNs: 1_000_000
        )

        var seen: DockerEvent?
        for await event in stream where event.Action == "die" {
            seen = event
            break
        }

        #expect(seen?.Actor.Attributes["exitCode"] == "7")
        #expect(seen?.Actor.ID == "abc123")
        #expect(seen?.Actor.Attributes["com.docker.compose.project"] == "demo")
        await ContainerExitCodeStore.shared.remove(id: "monitor-die")
        await ContainerExitCodeStore.shared.remove(id: "abc123")
    }

    @Test("stays silent when the start route already owns the exit")
    func silentWhenOwned() async {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        #expect(await DieEventOwnership.shared.claim(id: "monitor-owned"))

        _ = await ContainerProcessExitMonitor.run(
            wait: { 0 },
            hexId: "def456",
            nativeId: "monitor-owned",
            fallbackImage: "alpine:3.20",
            fallbackLabels: [:],
            dnsServer: nil,
            broadcaster: broadcaster,
            outputFlushGraceNs: 1_000_000
        )

        // Drain with a bounded read instead of a background collector: the stream stays open,
        // so a plain loop would block forever waiting for an event that must never arrive.
        let dieSeen = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in stream where event.Action == "die" {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        #expect(dieSeen == false)
        await DieEventOwnership.shared.release(id: "monitor-owned")
        await ContainerExitCodeStore.shared.remove(id: "monitor-owned")
        await ContainerExitCodeStore.shared.remove(id: "def456")
    }
}
