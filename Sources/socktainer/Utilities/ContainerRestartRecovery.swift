import ContainerResource
import Logging

/// Restores only instances that Socktainer owns or that explicitly opted into a
/// restart policy. A native name can be reused, so every decision uses its Docker ID.
///
/// Persistence itself lives in `ClientContainerService` and `RestartPolicyOverrideStore`:
/// every start/stop/exit that flows through the client records durable evidence, so this
/// pass only reads that evidence and re-arms the in-memory machinery — it wraps no client
/// and changes no route.
enum ContainerRestartRecovery {
    typealias ExitWaiter = @Sendable (String) async throws -> Int32

    enum SkipReason: String, Sendable {
        case sidecar
        case replacedOrRemoved
        case unmanaged
        case removalPending
        case startPending
        case missingStartEvidence
        case manuallyStopped
        case policyDoesNotRestore
        case missingExitEvidence
        case retryBudgetUnknown
        case retryBudgetExhausted
        case unsupportedStatus
    }

    struct Skipped: Sendable {
        let id: String
        let reason: SkipReason
    }

    struct Failure: Sendable {
        let id: String
        let reason: String
    }

    struct Report: Sendable {
        var adopted: [String] = []
        var started: [String] = []
        var skipped: [Skipped] = []
        var failed: [Failure] = []
        var waitTasks: [Task<Void, Never>] = []

        func cancelWaiters() async {
            for task in waitTasks { task.cancel() }
            for task in waitTasks { await task.value }
        }
    }

    static func recover(
        client: any ClientContainerProtocol,
        store: RestartPolicyOverrideStore = .shared,
        broadcaster: EventBroadcaster,
        dnsServer: SocktainerDNSServer? = nil,
        healthManager: HealthCheckManager? = nil,
        logger: Logger,
        waitForExit: @escaping ExitWaiter = { try await ContainerInitExitWaiter.wait(nativeId: $0) }
    ) async -> Report {
        var report = Report()
        let containers: [ContainerSnapshot]
        do {
            containers = try await client.list(showAll: true, filters: [:])
        } catch {
            logger.error("restart-recovery: could not list containers: \(error)")
            report.failed.append(Failure(id: "*", reason: String(describing: error)))
            return report
        }

        for listed in containers {
            let hexId = DockerContainerID.hexId(for: listed)
            do {
                if ClientContainerService.isDNSSidecar(listed) {
                    report.skipped.append(Skipped(id: hexId, reason: .sidecar))
                    continue
                }
                guard let container = try await client.getContainer(id: hexId),
                    DockerContainerID.hexId(for: container) == hexId,
                    !ClientContainerService.isDNSSidecar(container)
                else {
                    report.skipped.append(Skipped(id: hexId, reason: .replacedOrRemoved))
                    continue
                }
                let record = await store.lifecycle(id: hexId)
                let policy = await store.get(id: hexId) ?? RestartPolicyManager.decode(from: container.configuration.labels)
                guard record != nil || policy != nil else {
                    report.skipped.append(Skipped(id: hexId, reason: .unmanaged))
                    continue
                }
                guard record?.pendingAction != .remove else {
                    report.skipped.append(Skipped(id: hexId, reason: .removalPending))
                    continue
                }

                // The durable attempt count is the only one that survives this
                // daemon, and inspect reports the in-memory counter. Restore it
                // for every managed instance — including stopped ones recovery
                // leaves alone — so a skipped instance keeps the RestartCount it
                // had before the restart instead of reporting a fresh zero.
                await ContainerRestartState.shared.restoreAttempts(id: container.id, count: record?.restartAttempts ?? 0)

                if container.status == .running {
                    try await store.recordObservedRunning(id: hexId)
                    await ContainerExitCodeStore.shared.remove(id: container.id)
                    let generation = await ContainerRestartState.shared.currentGeneration(id: container.id)
                    let codeGeneration = await ContainerExitCodeStore.shared.currentGeneration(id: container.id)
                    let runEpoch = await DieEventOwnership.shared.beginRun(id: container.id)
                    let observedRecord = await store.lifecycle(id: hexId)
                    let manualStop = observedRecord?.manuallyStopped == true || observedRecord?.pendingAction == .stop
                    await armObserver(
                        container: container, policy: policy, generation: generation, runEpoch: runEpoch,
                        client: client, broadcaster: broadcaster,
                        dnsServer: dnsServer, healthManager: healthManager, logger: logger
                    )
                    // armRestartObserver consumes any explicit-stop mark so a restart is
                    // never mistaken for a manual stop; re-mark after arming so a stop
                    // that was still in flight when the daemon died keeps suppressing
                    // restart-policy enforcement on this adopted run's exit.
                    if manualStop {
                        await ContainerRestartState.shared.markExplicitlyStopped(id: container.id)
                    }
                    report.waitTasks.append(
                        observeExistingProcess(
                            nativeId: container.id, hexId: hexId, codeGeneration: codeGeneration,
                            logger: logger, waitForExit: waitForExit
                        ))
                    report.adopted.append(hexId)
                    logger.info("restart-recovery: adopted running container \(container.id)")
                    continue
                }

                if let reason = stoppedSkipReason(status: container.status, record: record, policy: policy) {
                    report.skipped.append(Skipped(id: hexId, reason: reason))
                    logger.debug("restart-recovery: skipped \(container.id): \(reason.rawValue)")
                    continue
                }

                // Intent precedes the external side effect. If the daemon dies in
                // this interval, the next recovery will not invent a completed start.
                await ContainerRestartState.shared.reset(id: container.id)
                try await store.recordStartIntent(id: hexId)
                try await client.start(id: hexId, detachKeys: nil)
                // The start is durable evidence now: a fresh run clears the manual-stop
                // mark and the previous run's exit code. (A production client records
                // the same fact itself; recording it here keeps the store correct for
                // any client and leaves the failed-start intent readable above.)
                try await store.recordStarted(id: hexId)
                // The Engine keeps the persisted retry count across a daemon restart:
                // this start spends one unit of the same budget instead of resetting
                // it. The generic start path resets the count, so re-apply it for a
                // bounded `on-failure` policy and continue the in-session counter.
                if policy?.Name == "on-failure", let completedAttempts = record?.restartAttempts {
                    try await store.recordRestarted(id: hexId, attempt: completedAttempts + 1)
                    await ContainerRestartState.shared.restoreAttempts(id: container.id, count: completedAttempts + 1)
                }
                let runEpoch = await DieEventOwnership.shared.beginRun(id: container.id)
                let generation = await ContainerRestartState.shared.currentGeneration(id: container.id)
                let started = await ContainerStartRoute.performPostStartSetup(
                    id: hexId, client: client, dnsServer: dnsServer, healthManager: healthManager, logger: logger
                )
                // The canonical lookup must still describe the instance we started.
                if let started, DockerContainerID.hexId(for: started) != hexId {
                    throw RecoveryError.instanceReplaced
                }
                let snapshot = started ?? container
                await armObserver(
                    container: snapshot, policy: policy, generation: generation, runEpoch: runEpoch,
                    client: client, broadcaster: broadcaster,
                    dnsServer: dnsServer, healthManager: healthManager, logger: logger
                )
                await VolumeMountEvents.broadcastMounts(for: snapshot, containerId: hexId, broadcaster: broadcaster)
                await broadcaster.broadcast(DockerEvent.containerEvent("start", container: snapshot))
                report.started.append(hexId)
                logger.info("restart-recovery: started \(container.id)")
            } catch {
                report.failed.append(Failure(id: hexId, reason: String(describing: error)))
                logger.error("restart-recovery: failed for \(listed.id): \(error)")
            }
        }
        return report
    }

    private enum RecoveryError: Error {
        case instanceReplaced
        case invalidExitCode
    }

    private static func stoppedSkipReason(
        status: RuntimeStatus, record: RestartLifecycleRecord?, policy: RestartPolicy?
    ) -> SkipReason? {
        guard status == .stopped else { return .unsupportedStatus }
        if record?.pendingAction == .start { return .startPending }
        guard record?.hasStarted == true else { return .missingStartEvidence }
        switch policy?.Name {
        case "always":
            // The Engine restores `always` after a daemon restart even when the
            // instance was manually stopped before it: the restart manager is
            // recreated on startup and its cancellation is in-memory only.
            return nil
        case "unless-stopped":
            if record?.manuallyStopped == true || record?.pendingAction == .stop {
                return .manuallyStopped
            }
            return nil
        case "on-failure":
            // The Engine also restores a manually stopped `on-failure` instance
            // after a daemon restart when its durable final exit code is
            // non-zero and retry budget remains: the in-memory stop cancellation
            // does not survive the restart either. A missing exit fact, or the
            // wait-failure sentinel, means the real code is unknown — an unknown
            // code must never be read as a failure and force a start (legacy
            // records and unrecorded exits stay down).
            guard let exitCode = record?.lastExitCode, exitCode >= 0 else {
                return .missingExitEvidence
            }
            guard exitCode != 0 else { return .policyDoesNotRestore }
            let maxRetries = policy?.MaximumRetryCount ?? 0
            if maxRetries <= 0 { return nil }
            // A bounded budget that cannot be reconstructed must not be spent blind.
            guard let completedAttempts = record?.restartAttempts else { return .retryBudgetUnknown }
            guard completedAttempts + 1 <= maxRetries else { return .retryBudgetExhausted }
            return nil
        default:
            return .policyDoesNotRestore
        }
    }

    private static func armObserver(
        container: ContainerSnapshot, policy: RestartPolicy?, generation: Int, runEpoch: Int,
        client: any ClientContainerProtocol, broadcaster: EventBroadcaster,
        dnsServer: SocktainerDNSServer?, healthManager: HealthCheckManager?, logger: Logger
    ) async {
        await ContainerStartRoute.armRestartObserver(
            nativeId: container.id, eventId: DockerContainerID.hexId(for: container),
            image: container.configuration.image.reference, name: container.id,
            labels: LabelNormalization.restore(container.configuration.labels),
            ip: ContainerStartRoute.dnsAttachmentIP(in: container), refreshCache: true,
            restartPolicy: policy, generation: generation, runEpoch: runEpoch,
            broadcaster: broadcaster, dnsServer: dnsServer, healthManager: healthManager,
            client: client, logger: logger
        )
    }

    private static func observeExistingProcess(
        nativeId: String, hexId: String, codeGeneration: Int,
        logger: Logger, waitForExit: @escaping ExitWaiter
    ) -> Task<Void, Never> {
        Task {
            let code: Int32
            do {
                try Task.checkCancellation()
                code = try await waitForExit(nativeId)
                try Task.checkCancellation()
                guard code >= 0 else { throw RecoveryError.invalidExitCode }
            } catch {
                if Task.isCancelled {
                    logger.debug("restart-recovery: cancelled exit wait for \(nativeId)")
                } else {
                    logger.error("restart-recovery: exit wait failed for \(nativeId): \(error)")
                }
                // Apple discards historical init exit codes after teardown. Retrying
                // by container name could observe a different run, so fail visibly.
                // Cancellation also wakes the armed observer; otherwise its checked
                // continuation would outlive the only producer that could resume it.
                await ContainerExitCodeStore.shared.set(
                    id: nativeId, code: ContainerExitCodeStore.waitFailureSentinel, generation: codeGeneration)
                return
            }
            await ContainerExitCodeStore.shared.set(id: nativeId, code: code, generation: codeGeneration)
            // Commit the real final exit code durably: the recovery decision for a
            // stopped instance needs it to survive this daemon. A failed write only
            // degrades a later recovery to a conservative skip, never to a restart
            // on an invented code.
            do {
                try await RestartPolicyOverrideStore.shared.recordExit(id: hexId, code: code)
            } catch {
                logger.error("restart-recovery: could not persist the final exit code for \(hexId): \(error)")
            }
        }
    }
}
