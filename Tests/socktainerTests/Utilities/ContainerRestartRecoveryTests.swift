import ContainerResource
import ContainerXPC
import Foundation
import Logging
import Testing

@testable import socktainer

@Suite("Container restart recovery")
struct ContainerRestartRecoveryTests {
    @Test("A fresh daemon restores a previously started always container, even after a manual stop")
    func restoresAlwaysFromReloadedStore() async throws {
        let snapshot = try recoverySnapshot(policy: "always")
        let id = DockerContainerID.hexId(for: snapshot)
        let directory = try temporaryRecoveryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = RestartPolicyOverrideStore()
        try await previous.configure(storageDirectory: directory)
        try await previous.recordStarted(id: id)
        try await previous.recordStopIntent(id: id, hasStarted: true)
        try await previous.recordStopped(id: id)
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        let client = RecoveryClient(snapshot: snapshot)
        let broadcaster = EventBroadcaster()

        let report = await recover(client: client, store: store, broadcaster: broadcaster)

        #expect(report.started == [id])
        #expect(report.failed.isEmpty)
        #expect(report.waitTasks.isEmpty, "A new start already has a producer in ClientContainerService")
        #expect(await client.startCount == 1)
        #expect(await store.lifecycle(id: id) == RestartLifecycleRecord(hasStarted: true, manuallyStopped: false, pendingAction: nil))
        #expect(await broadcaster.emittedRecently(id: id, action: "start", within: 60))
        await cleanUpRecovery(snapshot)
    }

    @Test("A stopped instance recovery leaves alone keeps its durable RestartCount")
    func stoppedSkipKeepsDurableRestartCount() async throws {
        let snapshot = try recoverySnapshot(policy: "on-failure")
        let id = DockerContainerID.hexId(for: snapshot)
        let store = RestartPolicyOverrideStore()
        await store.set(id: id, policy: RestartPolicy(Name: "on-failure", MaximumRetryCount: 1))
        try await store.recordStarted(id: id)
        // One restart already spent; the exit that exhausted the budget followed it.
        try await store.recordRestarted(id: id, attempt: 1)
        try await store.recordExit(id: id, code: 7)
        let client = RecoveryClient(snapshot: snapshot)

        let report = await recover(client: client, store: store)

        #expect(report.skipped.first?.reason == .retryBudgetExhausted)
        #expect(await client.startCount == 0)
        // inspect reports the in-memory counter: a skipped instance must keep the
        // durable count across the daemon restart, not report a fresh zero.
        #expect(await ContainerRestartState.shared.count(id: snapshot.id) == 1)
        await cleanUpRecovery(snapshot)
    }

    @Test("A pending or completed manual stop keeps unless-stopped down after reload", arguments: [true, false])
    func respectsManualStop(pending: Bool) async throws {
        let snapshot = try recoverySnapshot(policy: "unless-stopped")
        let id = DockerContainerID.hexId(for: snapshot)
        let directory = try temporaryRecoveryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = RestartPolicyOverrideStore()
        try await previous.configure(storageDirectory: directory)
        try await previous.recordStopIntent(id: id, hasStarted: true)
        if !pending { try await previous.recordStopped(id: id) }
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        let client = RecoveryClient(snapshot: snapshot)

        let report = await recover(client: client, store: store)

        #expect(report.skipped.first?.reason == .manuallyStopped)
        #expect(report.started.isEmpty)
        #expect(await client.startCount == 0)
        #expect(await store.lifecycle(id: id)?.manuallyStopped == true)
    }

    @Test("Never-started and on-failure containers are not booted during recovery", arguments: ["never", "on-failure", "no", "pending-start", "pending-remove"])
    func skipsUnprovenOrIneligibleStarts(scenario: String) async throws {
        let snapshot = try recoverySnapshot(policy: scenario == "on-failure" || scenario == "no" ? scenario : "always")
        let id = DockerContainerID.hexId(for: snapshot)
        let store = RestartPolicyOverrideStore()
        if scenario != "never" { try await store.recordStarted(id: id) }
        if scenario == "pending-start" { try await store.recordStartIntent(id: id) }
        if scenario == "pending-remove" { try await store.recordRemoveIntent(id: id) }
        let client = RecoveryClient(snapshot: snapshot)

        let report = await recover(client: client, store: store)

        #expect(report.skipped.count == 1)
        #expect(report.started.isEmpty)
        #expect(report.failed.isEmpty)
        #expect(await client.startCount == 0)
    }

    @Test("Legacy overrides supply a policy but no evidence of a previous start")
    func skipsLegacyPolicyWithoutEvidence() async throws {
        let snapshot = try recoverySnapshot(policy: nil)
        let id = DockerContainerID.hexId(for: snapshot)
        let directory = try temporaryRecoveryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try JSONEncoder().encode([id: RestartPolicy(Name: "always", MaximumRetryCount: nil)])
        try data.write(to: directory.appendingPathComponent("socktainer-restart-policy-overrides.json"))
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        let client = RecoveryClient(snapshot: snapshot)

        let report = await recover(client: client, store: store)

        #expect(report.skipped.first?.reason == .missingStartEvidence)
        #expect(await client.startCount == 0)
    }

    @Test("Running containers are adopted without replaying start and report their real exit")
    func adoptsRunningWithoutHistoricalEvents() async throws {
        let snapshot = try recoverySnapshot(policy: "no", status: .running)
        let id = DockerContainerID.hexId(for: snapshot)
        let store = RestartPolicyOverrideStore()
        let client = RecoveryClient(snapshot: snapshot)
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let firstDie = Task { () -> DockerEvent? in
            for await event in stream where event.Action == "die" { return event }
            return nil
        }

        let report = await recover(client: client, store: store, broadcaster: broadcaster, waitForExit: { _ in 7 })
        for task in report.waitTasks { await task.value }
        let emitted = try await recoveryEventually {
            await broadcaster.emittedRecently(id: id, action: "die", within: 60)
        }
        #expect(emitted)
        if !emitted { firstDie.cancel() }
        let event = await firstDie.value

        #expect(report.adopted == [id])
        #expect(await client.startCount == 0)
        #expect(await store.lifecycle(id: id)?.hasStarted == true)
        #expect(await ContainerExitCodeStore.shared.get(id: snapshot.id) == 7)
        #expect(event?.Actor.Attributes["exitCode"] == "7")
        // The start route timestamps its observer when it arms, so an adopted run
        // reports the time since adoption rather than the instance's real age.
        #expect(Int(event?.Actor.Attributes["execDuration"] ?? "") ?? -1 >= 0)
        #expect(!(await broadcaster.emittedRecently(id: id, action: "start", within: 60)))
        await cleanUpRecovery(snapshot)
    }

    @Test("Adopting a running container preserves a pending manual stop")
    func preservesRunningManualStop() async throws {
        let snapshot = try recoverySnapshot(policy: "unless-stopped", status: .running)
        let id = DockerContainerID.hexId(for: snapshot)
        let store = RestartPolicyOverrideStore()
        try await store.recordStopIntent(id: id, hasStarted: false)
        let client = RecoveryClient(snapshot: snapshot)
        let broadcaster = EventBroadcaster()

        let report = await recover(client: client, store: store, broadcaster: broadcaster, waitForExit: { _ in 0 })
        for task in report.waitTasks { await task.value }
        let emitted = try await recoveryEventually {
            await broadcaster.emittedRecently(id: id, action: "die", within: 60)
        }
        #expect(emitted)
        #expect(await store.lifecycle(id: id) == RestartLifecycleRecord(hasStarted: true, manuallyStopped: true, pendingAction: .stop))
        // Observe beyond the policy's first backoff so an erased stop flag is visible.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await client.startCount == 0)
        await cleanUpRecovery(snapshot)
    }

    @Test("A reused native name does not inherit the deleted instance's restart state")
    func rejectsRecreatedInstance() async throws {
        let previous = try recoverySnapshot(policy: "always")
        var replacement = previous
        replacement.configuration.labels[AppleContainerTimestampResolver.legacyCreationTimestampLabel] = "200"
        let store = RestartPolicyOverrideStore()
        try await store.recordStarted(id: DockerContainerID.hexId(for: previous))
        let client = RecoveryClient(snapshot: replacement, listedSnapshot: previous)

        let report = await recover(client: client, store: store)

        #expect(report.skipped.first?.reason == .replacedOrRemoved)
        #expect(await client.startCount == 0)
        #expect(await store.lifecycle(id: DockerContainerID.hexId(for: replacement)) == nil)
    }

    @Test("DNS sidecars and unowned native containers are excluded")
    func excludesUnmanagedContainers() async throws {
        var sidecar = try recoverySnapshot(policy: "always", status: .running)
        sidecar.configuration.labels[NetworkDNSManager.roleLabel] = NetworkDNSManager.dnsRole
        let unmanaged = try recoverySnapshot(policy: nil, status: .running)
        let store = RestartPolicyOverrideStore()
        let sidecarReport = await recover(client: RecoveryClient(snapshot: sidecar), store: store)
        let unmanagedReport = await recover(client: RecoveryClient(snapshot: unmanaged), store: store)
        #expect(sidecarReport.skipped.first?.reason == .sidecar)
        #expect(unmanagedReport.skipped.first?.reason == .unmanaged)
        #expect(sidecarReport.waitTasks.isEmpty)
        #expect(unmanagedReport.waitTasks.isEmpty)
    }

    @Test("Wait failures remain unknown exits and cannot trigger on-failure")
    func waitFailureDoesNotBecomeSuccessOrRestart() async throws {
        let snapshot = try recoverySnapshot(policy: "on-failure", status: .running)
        let id = DockerContainerID.hexId(for: snapshot)
        let client = RecoveryClient(snapshot: snapshot)
        let broadcaster = EventBroadcaster()
        let report = await recover(client: client, store: RestartPolicyOverrideStore(), broadcaster: broadcaster) { _ in
            throw RecoveryTestError.waitFailed
        }
        for task in report.waitTasks { await task.value }
        try await Task.sleep(for: .milliseconds(150))

        #expect(await ContainerExitCodeStore.shared.get(id: snapshot.id) == ContainerExitCodeStore.waitFailureSentinel)
        #expect(!(await broadcaster.emittedRecently(id: id, action: "die", within: 60)))
        #expect(await client.startCount == 0)
        await cleanUpRecovery(snapshot)
    }

    @Test("A waiter from a previous generation cannot overwrite a newer run")
    func rejectsStaleWaiter() async throws {
        let snapshot = try recoverySnapshot(policy: "no", status: .running)
        let gate = RecoveryExitGate()
        let report = await recover(client: RecoveryClient(snapshot: snapshot), store: RestartPolicyOverrideStore()) { _ in
            await gate.wait()
        }
        await ContainerRestartState.shared.reset(id: snapshot.id)
        await ContainerExitCodeStore.shared.remove(id: snapshot.id)
        await ContainerExitCodeStore.shared.set(id: snapshot.id, code: 23)
        await gate.complete(7)
        for task in report.waitTasks { await task.value }
        #expect(await ContainerExitCodeStore.shared.get(id: snapshot.id) == 23)
        await cleanUpRecovery(snapshot)
    }

    @Test("Cancelling an adopted waiter releases the exit observer without reporting a process exit")
    func cancellationRecordsUnknownExit() async throws {
        let snapshot = try recoverySnapshot(policy: "always", status: .running)
        let id = DockerContainerID.hexId(for: snapshot)
        let client = RecoveryClient(snapshot: snapshot)
        let broadcaster = EventBroadcaster()
        let report = await recover(client: client, store: RestartPolicyOverrideStore(), broadcaster: broadcaster) { _ in
            try await Task.sleep(for: .seconds(60))
            return 0
        }
        await report.cancelWaiters()
        let code = await ContainerExitCodeStore.shared.get(id: snapshot.id)
        #expect(code == ContainerExitCodeStore.waitFailureSentinel)
        // The sentinel must resolve both already-suspended and not-yet-scheduled observers.
        if code != nil {
            #expect(await ContainerExitCodeStore.shared.waitForCode(id: snapshot.id) == ContainerExitCodeStore.waitFailureSentinel)
        }
        // The observer must wake on the sentinel and abandon the run rather than
        // fabricate an exit: no die is broadcast and no restart is attempted.
        #expect(!(await broadcaster.emittedRecently(id: id, action: "die", within: 60)))
        #expect(await client.startCount == 0)
        await cleanUpRecovery(snapshot)
    }

    @Test("Start failures are reported and leave the incomplete start intent")
    func reportsStartFailure() async throws {
        let snapshot = try recoverySnapshot(policy: "always")
        let id = DockerContainerID.hexId(for: snapshot)
        let store = RestartPolicyOverrideStore()
        try await store.recordStarted(id: id)
        let client = RecoveryClient(snapshot: snapshot, failStart: true)
        let report = await recover(client: client, store: store)
        #expect(report.failed.map(\.id) == [id])
        #expect(report.started.isEmpty)
        #expect(await store.lifecycle(id: id)?.pendingAction == .start)
        await cleanUpRecovery(snapshot)
    }

    @Test("Existing-process replies require an explicit, nonnegative Int32 exit code")
    func validatesXPCExitCode() throws {
        let missing = XPCMessage(route: "test")
        #expect(throws: ContainerInitExitWaiter.InvalidResponse.self) { try ContainerInitExitWaiter.exitCode(from: missing) }
        let wrongType = XPCMessage(route: "test")
        wrongType.set(key: "exitCode", value: "0")
        #expect(throws: ContainerInitExitWaiter.InvalidResponse.self) { try ContainerInitExitWaiter.exitCode(from: wrongType) }
        for value in [Int64(-1), Int64(Int32.max) + 1] {
            let invalid = XPCMessage(route: "test")
            invalid.set(key: "exitCode", value: value)
            #expect(throws: ContainerInitExitWaiter.InvalidResponse.self) { try ContainerInitExitWaiter.exitCode(from: invalid) }
        }
        let valid = XPCMessage(route: "test")
        valid.set(key: "exitCode", value: Int64(17))
        #expect(try ContainerInitExitWaiter.exitCode(from: valid) == 17)
    }

    @Test("Changing the preferred observer does not discard an unchanged VM's exit reply")
    func redundantStartKeepsPhysicalWaiter() async throws {
        let snapshot = try recoverySnapshot(policy: "no", status: .running)
        let gate = RecoveryExitGate()
        let report = await recover(client: RecoveryClient(snapshot: snapshot), store: RestartPolicyOverrideStore()) { _ in await gate.wait() }
        await ContainerRestartState.shared.reset(id: snapshot.id)
        await gate.complete(9)
        for task in report.waitTasks { await task.value }
        #expect(await ContainerExitCodeStore.shared.get(id: snapshot.id) == 9)
        await cleanUpRecovery(snapshot)
    }

    @Test("A declined automatic restart removes the exited instance's DNS aliases")
    func declinedRestartCleansDNS() async throws {
        // A policy that declines the restart exercises the same observer path an
        // exhausted retry budget takes: the die is reported, the aliases go, and
        // no new run starts.
        let snapshot = try recoverySnapshot(policy: "no", status: .running)
        let store = RestartPolicyOverrideStore()
        let client = RecoveryClient(snapshot: snapshot)
        let dns = SocktainerDNSServer()
        ContainerStartRoute.registerDNSAliasesOnResume(container: snapshot, dnsServer: dns, logger: Logger(label: "recovery-dns"))
        #expect(!dns.listEntries().isEmpty)
        let report = await ContainerRestartRecovery.recover(
            client: client, store: store, broadcaster: EventBroadcaster(), dnsServer: dns,
            logger: Logger(label: "recovery-dns"), waitForExit: { _ in 7 })
        for task in report.waitTasks { await task.value }
        #expect(try await recoveryEventually { dns.listEntries().isEmpty })
        #expect(await client.startCount == 0)
        await cleanUpRecovery(snapshot)
    }

    @Test("A manually stopped on-failure instance is restored after a daemon restart when its real exit was a failure with budget left")
    func restoresManuallyStoppedOnFailureWithRealFailureExit() async throws {
        let snapshot = try recoverySnapshot(policy: "on-failure")
        let id = DockerContainerID.hexId(for: snapshot)
        let store = RestartPolicyOverrideStore()
        await store.set(id: id, policy: RestartPolicy(Name: "on-failure", MaximumRetryCount: 3))
        try await store.recordStarted(id: id)
        // The Engine restarts a manually stopped on-failure instance after a daemon
        // restart: the restart-manager cancellation is in-memory only, and the
        // durable exit code 7 with budget left satisfies ShouldRestart.
        try await store.recordExit(id: id, code: 7)
        try await store.recordStopIntent(id: id, hasStarted: true)
        try await store.recordStopped(id: id)
        let client = RecoveryClient(snapshot: snapshot)
        let broadcaster = EventBroadcaster()

        let report = await recover(client: client, store: store, broadcaster: broadcaster)

        #expect(report.started == [id])
        #expect(report.skipped.isEmpty)
        #expect(report.failed.isEmpty)
        #expect(await client.startCount == 1)
        // The restore spends one unit of the same budget instead of resetting it.
        #expect(await store.lifecycle(id: id)?.restartAttempts == 1)
        #expect(await ContainerRestartState.shared.count(id: snapshot.id) == 1)
        // The new run's exit is not yet known.
        #expect(await store.lifecycle(id: id)?.lastExitCode == nil)
        await cleanUpRecovery(snapshot)
    }

    @Test("A recovery restore continues the persisted retry budget instead of resetting it")
    func preservesRetryBudgetAcrossRecoveryRestore() async throws {
        let snapshot = try recoverySnapshot(policy: "on-failure")
        let id = DockerContainerID.hexId(for: snapshot)
        let store = RestartPolicyOverrideStore()
        await store.set(id: id, policy: RestartPolicy(Name: "on-failure", MaximumRetryCount: 3))
        try await store.recordStarted(id: id)
        // One restart already spent in a previous daemon session; the exit that
        // followed it is the durable fact recovery reads.
        try await store.recordRestarted(id: id, attempt: 1)
        try await store.recordExit(id: id, code: 7)
        let client = RecoveryClient(snapshot: snapshot)
        let report = await recover(client: client, store: store)

        #expect(report.started == [id])
        #expect(await store.lifecycle(id: id)?.restartAttempts == 2)
        #expect(await ContainerRestartState.shared.count(id: snapshot.id) == 2)
        await cleanUpRecovery(snapshot)
    }

    @Test("An on-failure instance without a durable real exit code stays down", arguments: [Int32?.none, ContainerExitCodeStore.waitFailureSentinel] as [Int32?])
    func skipsOnFailureWithoutRealExit(exitCode: Int32?) async throws {
        let snapshot = try recoverySnapshot(policy: "on-failure")
        let id = DockerContainerID.hexId(for: snapshot)
        let store = RestartPolicyOverrideStore()
        await store.set(id: id, policy: RestartPolicy(Name: "on-failure", MaximumRetryCount: 3))
        try await store.recordStarted(id: id)
        if let exitCode { try await store.recordExit(id: id, code: exitCode) }
        let client = RecoveryClient(snapshot: snapshot)

        let report = await recover(client: client, store: store)

        // An unknown code must never be read as a failure and force a start:
        // legacy records and unrecorded exits stay down.
        #expect(report.skipped.first?.reason == .missingExitEvidence)
        #expect(report.started.isEmpty)
        #expect(await client.startCount == 0)
        await cleanUpRecovery(snapshot)
    }

    @Test("An on-failure instance whose real exit was clean stays down")
    func skipsOnFailureOnCleanExit() async throws {
        let snapshot = try recoverySnapshot(policy: "on-failure")
        let id = DockerContainerID.hexId(for: snapshot)
        let store = RestartPolicyOverrideStore()
        await store.set(id: id, policy: RestartPolicy(Name: "on-failure", MaximumRetryCount: 3))
        try await store.recordStarted(id: id)
        try await store.recordExit(id: id, code: 0)
        let client = RecoveryClient(snapshot: snapshot)

        let report = await recover(client: client, store: store)

        #expect(report.skipped.first?.reason == .policyDoesNotRestore)
        #expect(report.started.isEmpty)
        #expect(await client.startCount == 0)
        await cleanUpRecovery(snapshot)
    }

    @Test("An on-failure instance with no reconstructable bounded budget stays down")
    func skipsOnFailureWithUnknownBudget() async throws {
        let snapshot = try recoverySnapshot(policy: "on-failure")
        let id = DockerContainerID.hexId(for: snapshot)
        let directory = try temporaryRecoveryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A lifecycle record written before retry counts were persisted: the
        // instance started and exited 7, but how much budget it spent is unknown.
        let legacy = #"{"schemaVersion":1,"overrides":{},"lifecycles":{"\#(id)":{"hasStarted":true,"manuallyStopped":true,"lastExitCode":7}}}"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("socktainer-restart-policy-overrides.json"))
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        await store.set(id: id, policy: RestartPolicy(Name: "on-failure", MaximumRetryCount: 3))
        let client = RecoveryClient(snapshot: snapshot)

        let report = await recover(client: client, store: store)

        #expect(report.skipped.first?.reason == .retryBudgetUnknown)
        #expect(report.started.isEmpty)
        #expect(await client.startCount == 0)
        await cleanUpRecovery(snapshot)
    }

    @Test("An on-failure instance whose bounded budget is spent stays down")
    func skipsOnFailureWhenBudgetExhausted() async throws {
        let snapshot = try recoverySnapshot(policy: "on-failure")
        let id = DockerContainerID.hexId(for: snapshot)
        let store = RestartPolicyOverrideStore()
        await store.set(id: id, policy: RestartPolicy(Name: "on-failure", MaximumRetryCount: 3))
        try await store.recordStarted(id: id)
        // All three restarts already spent in previous sessions; the exit that
        // followed the last one is the durable fact recovery reads.
        try await store.recordRestarted(id: id, attempt: 1)
        try await store.recordRestarted(id: id, attempt: 2)
        try await store.recordRestarted(id: id, attempt: 3)
        try await store.recordExit(id: id, code: 7)
        let client = RecoveryClient(snapshot: snapshot)

        let report = await recover(client: client, store: store)

        #expect(report.skipped.first?.reason == .retryBudgetExhausted)
        #expect(report.started.isEmpty)
        #expect(await client.startCount == 0)
        await cleanUpRecovery(snapshot)
    }

    @Test("An unbounded on-failure instance is restored on a real failure exit")
    func restoresUnboundedOnFailure() async throws {
        let snapshot = try recoverySnapshot(policy: "on-failure")
        let id = DockerContainerID.hexId(for: snapshot)
        let store = RestartPolicyOverrideStore()
        try await store.recordStarted(id: id)
        try await store.recordExit(id: id, code: 7)
        let client = RecoveryClient(snapshot: snapshot)

        let report = await recover(client: client, store: store)

        #expect(report.started == [id])
        #expect(await client.startCount == 1)
        await cleanUpRecovery(snapshot)
    }
}

private func recover(
    client: any ClientContainerProtocol, store: RestartPolicyOverrideStore,
    broadcaster: EventBroadcaster = EventBroadcaster(),
    waitForExit: @escaping ContainerRestartRecovery.ExitWaiter = { _ in throw RecoveryTestError.unexpectedWait }
) async -> ContainerRestartRecovery.Report {
    await ContainerRestartRecovery.recover(
        client: client, store: store, broadcaster: broadcaster,
        logger: Logger(label: "restart-recovery-test"), waitForExit: waitForExit
    )
}

private func recoverySnapshot(policy: String?, status: RuntimeStatus = .stopped) throws -> ContainerSnapshot {
    var labels = [AppleContainerTimestampResolver.legacyCreationTimestampLabel: "100"]
    if let policy {
        labels[RestartPolicyManager.label] = String(
            decoding: try JSONEncoder().encode(RestartPolicy(Name: policy, MaximumRetryCount: nil)), as: UTF8.self)
    }
    return try makeContainerSnapshot(
        nativeId: "recovery-\(UUID().uuidString)", ip: "192.168.65.30", network: "recovery_default", labels: labels, status: status)
}

private func temporaryRecoveryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("restart-recovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func cleanUpRecovery(_ snapshot: ContainerSnapshot) async {
    await ContainerRestartState.shared.reset(id: snapshot.id)
    // Resume any detached observer left by a successful mocked start.
    // Keep the unique fixture's sentinel available for observers not yet scheduled.
    await ContainerExitCodeStore.shared.set(id: snapshot.id, code: ContainerExitCodeStore.waitFailureSentinel)
    await DieEventOwnership.shared.forget(id: snapshot.id)
}

private func recoveryEventually(_ predicate: () async -> Bool) async throws -> Bool {
    for _ in 0..<200 {
        if await predicate() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private enum RecoveryTestError: Error {
    case waitFailed
    case startFailed
    case unexpectedWait
}

private actor RecoveryExitGate {
    private var result: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func wait() async -> Int32 {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func complete(_ code: Int32) {
        result = code
        continuation?.resume(returning: code)
        continuation = nil
    }
}

private actor RecoveryClient: ClientContainerProtocol {
    private var snapshot: ContainerSnapshot
    private let listedSnapshot: ContainerSnapshot
    private let failStart: Bool
    private(set) var startCount = 0

    init(snapshot: ContainerSnapshot, listedSnapshot: ContainerSnapshot? = nil, failStart: Bool = false) {
        self.snapshot = snapshot
        self.listedSnapshot = listedSnapshot ?? snapshot
        self.failStart = failStart
    }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [listedSnapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func prepareForStart(container: ContainerSnapshot) async throws {}
    func start(id: String, detachKeys: String?) async throws {
        startCount += 1
        if failStart { throw RecoveryTestError.startFailed }
        snapshot.status = .running
        await ContainerExitCodeStore.shared.remove(id: snapshot.id)
    }
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func rename(id: String, newName: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait { RESTContainerWait(statusCode: 0) }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
}
