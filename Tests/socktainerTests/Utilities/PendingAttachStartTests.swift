import ContainerAPIClient
import ContainerizationOS
import Foundation
import Testing

@testable import socktainer

/// Regression tests for socktainer/socktainer#472: attaching to a stopped container used to boot
/// and start it, so attached `docker compose up`, which attaches to every service before starting
/// any, started them all at once and ignored `depends_on`. The attach route now parks its pipes in
/// PendingAttachStart and `POST /start` boots the container with them.
@Suite("PendingAttachStart")
struct PendingAttachStartTests {

    private func makePipes() throws -> StdioPipes {
        try #require(StdioPipes.make(.all))
    }

    @Test("a start that finishes before the attach waits still reaches it")
    func finishBeforeWait() async throws {
        let registry = PendingAttachStart()
        let pipes = try makePipes()
        defer { pipes.closeAll() }
        let token = try #require(await registry.park(containerId: "c1", pipes: pipes))
        #expect(await registry.adopt(containerId: "c1", token: token))

        #expect(await registry.claim(containerId: "c1") != nil)
        await registry.finish(containerId: "c1", result: .success(StubProcess(id: "p1")))

        let process = try await registry.waitForStart(containerId: "c1", token: token)
        #expect(process.id == "p1")
    }

    @Test("an attach waiting for the start resumes once the start finishes")
    func waitThenFinish() async throws {
        let registry = PendingAttachStart()
        let pipes = try makePipes()
        defer { pipes.closeAll() }
        let token = try #require(await registry.park(containerId: "c1", pipes: pipes))
        #expect(await registry.adopt(containerId: "c1", token: token))

        let waiter = Task { try await registry.waitForStart(containerId: "c1", token: token) }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await registry.claim(containerId: "c1") != nil)
        await registry.finish(containerId: "c1", result: .success(StubProcess(id: "p2")))

        #expect(try await waiter.value.id == "p2")
    }

    @Test("a failed start ends the waiting attach with an error")
    func failedStart() async throws {
        let registry = PendingAttachStart()
        let pipes = try makePipes()
        defer { pipes.closeAll() }
        let token = try #require(await registry.park(containerId: "c1", pipes: pipes))
        #expect(await registry.adopt(containerId: "c1", token: token))

        let waiter = Task { try await registry.waitForStart(containerId: "c1", token: token) }
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = await registry.claim(containerId: "c1")
        await registry.finish(containerId: "c1", result: .failure(StubError()))

        await #expect(throws: StubError.self) { try await waiter.value }
    }

    @Test("a client that leaves before the start gets its pipes back, and the start finds none")
    func cancelBeforeClaim() async throws {
        let registry = PendingAttachStart()
        let pipes = try makePipes()
        defer { pipes.closeAll() }
        let token = try #require(await registry.park(containerId: "c1", pipes: pipes))

        let waiter = Task { try await registry.waitForStart(containerId: "c1", token: token) }
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(await registry.cancel(containerId: "c1", token: token), "the caller owns the pipes and must close them")
        await #expect(throws: PendingAttachStart.WaitError.self) { try await waiter.value }
        #expect(await registry.claim(containerId: "c1") == nil, "a later start must not boot with a departed client's pipes")
    }

    @Test("a client that leaves once the start has taken its pipes does not get them back")
    func cancelAfterClaim() async throws {
        let registry = PendingAttachStart()
        let pipes = try makePipes()
        defer { pipes.closeAll() }
        let token = try #require(await registry.park(containerId: "c1", pipes: pipes))
        #expect(await registry.adopt(containerId: "c1", token: token))

        #expect(await registry.claim(containerId: "c1") != nil)
        #expect(await registry.cancel(containerId: "c1", token: token) == false, "the start path owns the pipes now")

        await registry.finish(containerId: "c1", result: .success(StubProcess(id: "p3")))
        #expect(try await registry.waitForStart(containerId: "c1", token: token).id == "p3")
    }

    @Test("a second attach to the same stopped container is refused")
    func secondAttachRefused() async throws {
        let registry = PendingAttachStart()
        let first = try makePipes()
        let second = try makePipes()
        defer {
            first.closeAll()
            second.closeAll()
        }

        #expect(await registry.park(containerId: "c1", pipes: first) != nil)
        #expect(await registry.park(containerId: "c1", pipes: second) == nil)
        #expect(await registry.park(containerId: "c2", pipes: second) != nil, "other containers are unaffected")
    }

    @Test("pipes whose stream never started are released, and the container can be attached again")
    func unadoptedEntryReleased() async throws {
        let registry = PendingAttachStart(adoptionTimeoutNs: 50_000_000)
        let pipes = try makePipes()
        _ = try #require(await registry.park(containerId: "c1", pipes: pipes))

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(await registry.claim(containerId: "c1") == nil, "a start must not boot with pipes nobody reads")
        let again = try makePipes()
        defer { again.closeAll() }
        #expect(await registry.park(containerId: "c1", pipes: again) != nil, "a new attach must not get 409")
    }

    @Test("a start that arrives before the stream adopts its pipes waits for it")
    func claimWaitsForAdoption() async throws {
        let registry = PendingAttachStart()
        let pipes = try makePipes()
        defer { pipes.closeAll() }
        let token = try #require(await registry.park(containerId: "c1", pipes: pipes))

        let claim = Task { await registry.claim(containerId: "c1") }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await registry.adopt(containerId: "c1", token: token))

        #expect(await claim.value != nil)
    }

    @Test("a start waiting for adoption gets nothing when the entry is released instead")
    func claimGivesUpWhenUnadopted() async throws {
        let registry = PendingAttachStart(adoptionTimeoutNs: 50_000_000)
        let pipes = try makePipes()
        _ = try #require(await registry.park(containerId: "c1", pipes: pipes))

        #expect(await registry.claim(containerId: "c1") == nil)
    }

    @Test("an adopted entry outlives the adoption timeout")
    func adoptedEntryKept() async throws {
        let registry = PendingAttachStart(adoptionTimeoutNs: 50_000_000)
        let pipes = try makePipes()
        defer { pipes.closeAll() }
        let token = try #require(await registry.park(containerId: "c1", pipes: pipes))
        #expect(await registry.adopt(containerId: "c1", token: token))

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(await registry.claim(containerId: "c1") != nil, "Compose can take minutes to start a dependent service")
    }

    @Test("a start with no attach waiting boots without parked pipes")
    func claimWithoutAttach() async {
        #expect(await PendingAttachStart().claim(containerId: "nobody-attached") == nil)
    }

    @Test("awaitStart releases the parked pipes when the client goes away first")
    func awaitStartClientGone() async throws {
        let id = "pending-attach-gone-\(UUID().uuidString.lowercased())"
        let pipes = try makePipes()
        let token = try #require(await PendingAttachStart.shared.park(containerId: id, pipes: pipes))

        let process = await PendingAttachStart.awaitStart(containerId: id, token: token, pipes: pipes, clientGone: {})

        // awaitStart closed the pipes it withdrew; a later start finds none to boot with.
        #expect(process == nil)
        #expect(await PendingAttachStart.shared.claim(containerId: id) == nil)
    }

    @Test("awaitStart returns the process once the container is started")
    func awaitStartStarted() async throws {
        let id = "pending-attach-started-\(UUID().uuidString.lowercased())"
        let pipes = try makePipes()
        defer { pipes.closeAll() }
        let token = try #require(await PendingAttachStart.shared.park(containerId: id, pipes: pipes))

        let starter = Task {
            try await Task.sleep(nanoseconds: 20_000_000)
            _ = await PendingAttachStart.shared.claim(containerId: id)
            await PendingAttachStart.shared.finish(containerId: id, result: .success(StubProcess(id: "p4")))
        }
        let process = await PendingAttachStart.awaitStart(
            containerId: id, token: token, pipes: pipes,
            clientGone: { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) } })
        try await starter.value

        #expect(process?.id == "p4")
    }
}

private struct StubError: Error {}

private struct StubProcess: ClientProcess {
    let id: String
    func start() async throws {}
    func resize(_ size: Terminal.Size) async throws {}
    func kill(_ signal: Int32) async throws {}
    func wait() async throws -> Int32 { 0 }
}
