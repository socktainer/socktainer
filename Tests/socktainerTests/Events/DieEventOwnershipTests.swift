import Foundation
import Testing

@testable import socktainer

/// `docker compose up` starts a service by attaching to a stopped container; it never calls
/// `POST /start`. Only the attach route's exit monitor sees that exit, so it must emit `die` —
/// while `docker run`, which goes through both attach and start, must still emit exactly one.
@Suite("DieEventOwnership")
struct DieEventOwnershipTests {
    @Test("the monitor owns an exit nothing else reserved: the compose flow")
    func monitorOwnsUnreservedRun() async {
        let ownership = DieEventOwnership()
        let run = await ownership.beginRun(id: "c1")

        #expect(await ownership.claimForMonitor(id: "c1", epoch: run))
    }

    @Test("the monitor defers to a start-route reservation: the docker run flow")
    func startReservationWinsOverMonitor() async {
        let ownership = DieEventOwnership()
        let run = await ownership.beginRun(id: "c1")
        await ownership.reserveForStart(id: "c1", epoch: run, generation: 1)

        #expect(await ownership.claimForMonitor(id: "c1", epoch: run) == false)
        #expect(await ownership.claimForStart(id: "c1", epoch: run, generation: 1))
    }

    @Test("a redundant /start moves the obligation to the observer that stays current")
    func newerGenerationSupersedesReservation() async {
        let ownership = DieEventOwnership()
        // A redundant /start finds the container already running, so it joins the same run.
        let run = await ownership.beginRun(id: "c1")
        #expect(await ownership.beginRun(id: "c1") == run)

        await ownership.reserveForStart(id: "c1", epoch: run, generation: 1)
        await ownership.reserveForStart(id: "c1", epoch: run, generation: 2)

        // The stale observer must not emit even if its generation check somehow passed.
        #expect(await ownership.claimForStart(id: "c1", epoch: run, generation: 1) == false)
        #expect(await ownership.claimForStart(id: "c1", epoch: run, generation: 2))
    }

    @Test("a claimed run stays claimed, so a late observer cannot double-emit")
    func ownershipSurvivesTheRun() async {
        let ownership = DieEventOwnership()
        let run = await ownership.beginRun(id: "c1")

        #expect(await ownership.claimForMonitor(id: "c1", epoch: run))
        // Both losers arrive after the winner already broadcast. Handing the run back after a
        // broadcast would let either emit a second `die` for the same exit.
        #expect(await ownership.claimForMonitor(id: "c1", epoch: run) == false)
        await ownership.reserveForStart(id: "c1", epoch: run, generation: 1)
        #expect(await ownership.claimForStart(id: "c1", epoch: run, generation: 1) == false)
    }

    @Test("the concurrent attach and start of docker run land on one run")
    func concurrentAttachAndStartShareARun() async {
        let ownership = DieEventOwnership()

        // `docker run` attaches and starts concurrently; whichever request reaches the runtime
        // first starts the container and the other gets a benign "already booted", so both sides
        // open a run. Two runs for one exit would let each side's observer emit its own `die`.
        let started = await ownership.beginRun(id: "c1")
        let attached = await ownership.beginRun(id: "c1")
        #expect(started == attached)

        await ownership.reserveForStart(id: "c1", epoch: started, generation: 1)
        #expect(await ownership.claimForMonitor(id: "c1", epoch: attached) == false)
        #expect(await ownership.claimForStart(id: "c1", epoch: started, generation: 1))
    }

    @Test("a finished run is not joined: the next start opens a fresh one")
    func decidedRunIsNotJoined() async {
        let ownership = DieEventOwnership()
        let first = await ownership.beginRun(id: "c1")
        #expect(await ownership.claimForMonitor(id: "c1", epoch: first))

        let second = await ownership.beginRun(id: "c1")
        #expect(second != first)
        #expect(await ownership.claimForMonitor(id: "c1", epoch: second))
    }

    @Test("a restart always opens its own run, even before the old exit was reported")
    func restartNeverJoinsTheStoppedRun() async {
        let ownership = DieEventOwnership()
        let first = await ownership.beginRun(id: "c1")

        // `docker restart` of a running container: the stop ends run 1 whether or not its exit
        // has been reported yet, and the restarted container needs a reportable run of its own.
        let second = await ownership.beginRestartedRun(id: "c1")
        #expect(second != first)
        #expect(await ownership.claimForMonitor(id: "c1", epoch: first), "run 1's exit is still reportable")
        #expect(await ownership.claimForMonitor(id: "c1", epoch: second), "so is the restarted run's")
    }

    @Test("a monitor still resolving one exit cannot silence the next run")
    func staleMonitorCannotClaimTheNextRun() async {
        let ownership = DieEventOwnership()
        let first = await ownership.beginRun(id: "c1")

        // The container exits and restarts while the first run's monitor is still inside
        // `process.wait()`; it must land on its own run, not steal the live one.
        let second = await ownership.beginRestartedRun(id: "c1")
        #expect(await ownership.claimForMonitor(id: "c1", epoch: first))
        #expect(
            await ownership.claimForMonitor(id: "c1", epoch: second),
            "the current run must still be claimable after a lagging observer reports an older one"
        )
    }

    @Test("each restart is claimable again, including consecutive restart-policy restarts")
    func newRunReopensTheClaim() async {
        let ownership = DieEventOwnership()

        for generation in 1...3 {
            let run = await ownership.beginRestartedRun(id: "c1")
            await ownership.reserveForStart(id: "c1", epoch: run, generation: generation)
            #expect(
                await ownership.claimForStart(id: "c1", epoch: run, generation: generation),
                "restart \(generation) must be able to report its own exit"
            )
        }
    }

    @Test("a new run does not inherit the previous run's reservation")
    func newRunClearsReservation() async {
        let ownership = DieEventOwnership()
        let first = await ownership.beginRun(id: "c1")
        await ownership.reserveForStart(id: "c1", epoch: first, generation: 1)
        #expect(await ownership.claimForStart(id: "c1", epoch: first, generation: 1))

        // Re-attached without a /start: the monitor is the only observer of the new run.
        let second = await ownership.beginRun(id: "c1")
        #expect(await ownership.claimForMonitor(id: "c1", epoch: second))
    }

    @Test("a removed container's reported exit refuses later claims")
    func forgetRefusesLateClaimsForAReportedRun() async {
        let ownership = DieEventOwnership()
        let run = await ownership.beginRun(id: "c1")
        #expect(await ownership.claimForMonitor(id: "c1", epoch: run))

        // The `--rm` path cleans up after broadcasting, so a second observer of the same exit
        // must find nothing to claim — otherwise the dropped record hands it a fresh run and it
        // emits a duplicate `die`.
        await ownership.forget(id: "c1")

        await ownership.reserveForStart(id: "c1", epoch: run, generation: 1)
        #expect(await ownership.claimForStart(id: "c1", epoch: run, generation: 1) == false)
    }

    @Test("docker rm -f still lets the pending observer report the exit")
    func forgetKeepsAnOpenRunClaimable() async {
        let ownership = DieEventOwnership()
        let run = await ownership.beginRun(id: "c1")

        // `docker rm -f` stops and deletes a running container; its exit monitor resolves the
        // code only after the delete lands. Docker sends `die` for that exit, so refusing the
        // claim would make the event a race with teardown instead of dropping a duplicate.
        await ownership.forget(id: "c1")

        #expect(await ownership.claimForMonitor(id: "c1", epoch: run))
    }

    @Test("recreating a container under the same name reports its exits again")
    func recreatedContainerIsClaimableAgain() async {
        let ownership = DieEventOwnership()
        let run = await ownership.beginRun(id: "c1")
        #expect(await ownership.claimForMonitor(id: "c1", epoch: run))
        await ownership.forget(id: "c1")

        // `compose down` then `compose up` reuses the service's container name.
        let recreated = await ownership.beginRun(id: "c1")
        #expect(await ownership.claimForMonitor(id: "c1", epoch: recreated))
    }

    @Test("claims are independent per container")
    func independentContainers() async {
        let ownership = DieEventOwnership()
        let first = await ownership.beginRun(id: "c1")
        let second = await ownership.beginRun(id: "c2")

        #expect(await ownership.claimForMonitor(id: "c1", epoch: first))
        #expect(await ownership.claimForMonitor(id: "c2", epoch: second))
    }

    @Test("a container this process never started opens a run when an observer joins it")
    func attachedToForeignContainer() async {
        let ownership = DieEventOwnership()
        // Attaching to a container started before socktainer came up: no run was ever opened.
        let run = await ownership.beginRun(id: "c1")

        #expect(await ownership.claimForMonitor(id: "c1", epoch: run))
        #expect(await ownership.claimForMonitor(id: "c1", epoch: run) == false)
    }

    @Test("a recreated container does not inherit the deleted one's run")
    func recreationDoesNotReuseAnEpoch() async {
        let ownership = DieEventOwnership()
        let deleted = await ownership.beginRun(id: "c1")
        #expect(await ownership.claimForMonitor(id: "c1", epoch: deleted))
        await ownership.forget(id: "c1")

        // `compose up` after `down` recreates the service's container under the same name. With
        // per-container numbering it would be handed the same epoch, and the deleted container's
        // lagging observer could claim it — emitting a stale `die` and leaving this run mute.
        let recreated = await ownership.beginRun(id: "c1")
        #expect(recreated != deleted)
        #expect(
            await ownership.claimForMonitor(id: "c1", epoch: deleted) == false,
            "the deleted container's observer must not be able to claim the recreated run"
        )
        #expect(
            await ownership.claimForMonitor(id: "c1", epoch: recreated),
            "the recreated container must still be able to report its own exit"
        )
    }

    @Test("a container recreated after rm -f does not join the dead container's open run")
    func recreationAfterForceRemoveOpensItsOwnRun() async {
        let ownership = DieEventOwnership()
        let dead = await ownership.beginRun(id: "c1")

        // `docker rm -f` deletes a running container: its record stays claimable because the
        // exit monitor still has to report that exit. The *name* must stop pointing at it, or a
        // container recreated under the same name shares a run with a dead one — whoever claims
        // first wins and the other exit is never reported.
        await ownership.forget(id: "c1")

        let recreated = await ownership.beginRun(id: "c1")
        #expect(recreated != dead)
        #expect(
            await ownership.claimForMonitor(id: "c1", epoch: dead),
            "the removed container's pending observer must still report its exit"
        )
        #expect(
            await ownership.claimForMonitor(id: "c1", epoch: recreated),
            "and the recreated container must be able to report its own"
        )
        // The removed container's record is released once its exit was reported, so a second
        // observer of that same exit finds nothing to claim.
        #expect(await ownership.claimForMonitor(id: "c1", epoch: dead) == false)
    }

    @Test("a claim naming a run that is no longer tracked is refused")
    func untrackedRunIsNotClaimable() async {
        let ownership = DieEventOwnership()
        let run = await ownership.beginRun(id: "c1")
        #expect(await ownership.claimForMonitor(id: "c1", epoch: run))
        await ownership.forget(id: "c1")

        // Treating an unknown run as a fresh one is what would let a late observer emit a second
        // `die` for an exit that was already reported.
        #expect(await ownership.claimForMonitor(id: "c1", epoch: run) == false)
        await ownership.reserveForStart(id: "c1", epoch: run, generation: 1)
        #expect(await ownership.claimForStart(id: "c1", epoch: run, generation: 1) == false)
    }

    @Test("epochs are unique across containers, not just across a container's runs")
    func epochsAreGloballyUnique() async {
        let ownership = DieEventOwnership()

        let first = await ownership.beginRun(id: "c1")
        let second = await ownership.beginRun(id: "c2")
        let third = await ownership.beginRestartedRun(id: "c1")

        #expect(Set([first, second, third]).count == 3)
    }
}

@Suite("ContainerProcessExitMonitor die event")
struct ContainerProcessExitMonitorDieTests {
    /// Reads the stream with a deadline: a regression that stops emitting `die` must fail the
    /// test, not hang the suite waiting for an event that never arrives.
    private static func firstDieEvent(
        in stream: AsyncStream<DockerEvent>,
        withinNs: UInt64 = 2_000_000_000
    ) async -> DockerEvent? {
        await withTaskGroup(of: DockerEvent?.self) { group in
            group.addTask {
                for await event in stream where event.Action == "die" {
                    return event
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: withinNs)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Test("emits die with the exit code when nothing else owns the exit")
    func emitsDieWhenUnowned() async {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let run = await DieEventOwnership.shared.beginRun(id: "monitor-die")

        _ = await ContainerProcessExitMonitor.run(
            wait: { 7 },
            hexId: "abc123",
            nativeId: "monitor-die",
            fallbackImage: "alpine:3.20",
            fallbackLabels: ["com.docker.compose.project": "demo"],
            dnsServer: nil,
            broadcaster: broadcaster,
            runEpoch: run,
            outputFlushGraceNs: 1_000_000
        )

        let seen = await Self.firstDieEvent(in: stream)

        #expect(seen?.Actor.Attributes["exitCode"] == "7")
        #expect(seen?.Actor.ID == "abc123")
        #expect(seen?.Actor.Attributes["com.docker.compose.project"] == "demo")
        await ContainerExitCodeStore.shared.remove(id: "monitor-die")
        await ContainerExitCodeStore.shared.remove(id: "abc123")
    }

    @Test("stays silent when a start-route observer reserved the exit")
    func silentWhenReserved() async {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let run = await DieEventOwnership.shared.beginRun(id: "monitor-owned")
        await DieEventOwnership.shared.reserveForStart(id: "monitor-owned", epoch: run, generation: 1)

        _ = await ContainerProcessExitMonitor.run(
            wait: { 0 },
            hexId: "def456",
            nativeId: "monitor-owned",
            fallbackImage: "alpine:3.20",
            fallbackLabels: [:],
            dnsServer: nil,
            broadcaster: broadcaster,
            runEpoch: run,
            outputFlushGraceNs: 1_000_000
        )

        let seen = await Self.firstDieEvent(in: stream, withinNs: 300_000_000)

        #expect(seen == nil)
        await ContainerExitCodeStore.shared.remove(id: "monitor-owned")
        await ContainerExitCodeStore.shared.remove(id: "def456")
    }

    @Test("the monitor's claim survives its broadcast, blocking a late start observer")
    func monitorKeepsOwnershipAfterBroadcast() async {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()

        let run = await DieEventOwnership.shared.beginRun(id: "monitor-keeps")

        _ = await ContainerProcessExitMonitor.run(
            wait: { 3 },
            hexId: "keeps123",
            nativeId: "monitor-keeps",
            fallbackImage: "alpine:3.20",
            fallbackLabels: [:],
            dnsServer: nil,
            broadcaster: broadcaster,
            runEpoch: run,
            outputFlushGraceNs: 1_000_000
        )

        #expect(await Self.firstDieEvent(in: stream)?.Actor.Attributes["exitCode"] == "3")

        // A /start arriving after the container already exited must not emit a second event.
        await DieEventOwnership.shared.reserveForStart(id: "monitor-keeps", epoch: run, generation: 1)
        #expect(await DieEventOwnership.shared.claimForStart(id: "monitor-keeps", epoch: run, generation: 1) == false)

        await ContainerExitCodeStore.shared.remove(id: "monitor-keeps")
        await ContainerExitCodeStore.shared.remove(id: "keeps123")
    }
    @Test("the loser of the exit claim leaves --rm cleanup to the winner")
    func onlyTheExitOwnerRunsAutoRemove() async {
        // `destroy` must follow the `die` it belongs to. The claim loser reaches the auto-remove
        // gate while the winner is still inside its output-flush grace, so if it performed the
        // cleanup it would publish `destroy` first and a client treating that as terminal — like
        // Compose's --abort-on-container-exit — would never see the exit.
        let broadcaster = EventBroadcaster()
        let run = await DieEventOwnership.shared.beginRun(id: "monitor-loses-rm")
        await DieEventOwnership.shared.reserveForStart(id: "monitor-loses-rm", epoch: run, generation: 1)
        await ContainerInfoCache.shared.markAutoRemove(hexId: "rm123", nativeId: "monitor-loses-rm")

        _ = await ContainerProcessExitMonitor.run(
            wait: { 0 },
            hexId: "rm123",
            nativeId: "monitor-loses-rm",
            fallbackImage: "alpine:3.20",
            fallbackLabels: [:],
            dnsServer: nil,
            broadcaster: broadcaster,
            runEpoch: run,
            outputFlushGraceNs: 1_000_000
        )

        #expect(
            await ContainerInfoCache.shared.consumeAutoRemove(id: "rm123"),
            "the --rm mark must be left for the observer that reports the exit"
        )
        await ContainerExitCodeStore.shared.remove(id: "monitor-loses-rm")
        await ContainerExitCodeStore.shared.remove(id: "rm123")
    }

    @Test("with no broadcaster the monitor still performs --rm cleanup")
    func autoRemoveStillRunsWithoutABroadcaster() async {
        // Nothing can emit events, so there is no ordering to protect — but the container must
        // still be reaped, since Apple Container never delivers a DELETE for it.
        let run = await DieEventOwnership.shared.beginRun(id: "no-broadcaster-rm")
        await ContainerInfoCache.shared.markAutoRemove(hexId: "rm456", nativeId: "no-broadcaster-rm")

        _ = await ContainerProcessExitMonitor.run(
            wait: { 0 },
            hexId: "rm456",
            nativeId: "no-broadcaster-rm",
            fallbackImage: "alpine:3.20",
            fallbackLabels: [:],
            dnsServer: nil,
            broadcaster: nil,
            runEpoch: run,
            outputFlushGraceNs: 1_000_000
        )

        #expect(
            await ContainerInfoCache.shared.consumeAutoRemove(id: "rm456") == false,
            "the monitor must have consumed the --rm mark itself"
        )
        await ContainerExitCodeStore.shared.remove(id: "no-broadcaster-rm")
        await ContainerExitCodeStore.shared.remove(id: "rm456")
    }
}
