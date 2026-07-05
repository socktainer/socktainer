import ContainerAPIClient
import ContainerResource
import Foundation
import Logging

/// Detects containers whose `VZVirtualMachine` died without ever generating an exit event.
///
/// Apple Container's exit-wait RPC (`RuntimeService.ExitWaiter`) only completes when the guest
/// itself reports its exit over vsock, and Apple's stack never registers a
/// `VZVirtualMachineDelegate` to observe an unexpected VM stop independently. A VM that dies (or
/// whose guest permanently wedges — e.g. a virtio-net interface that never recovers from the host
/// contention this project has already diagnosed) is therefore invisible to socktainer until
/// something explicitly interacts with it, by which point it may have been silently unreachable
/// for minutes with `RestartPolicy` never getting a chance to engage.
///
/// This periodically probes each running container via `stats(id:)` — a real vsock round-trip,
/// the same call `ContainerStatsRoute` already makes — and, after enough consecutive failures to
/// rule out a transient stall, forces Apple's runtime to notice the VM is gone and synthesizes
/// the exit code the normal exit-wait path would have delivered. That unblocks the existing
/// die-event observer in `ContainerStartRoute`, so `RestartPolicy` takes over exactly as it would
/// for a cleanly-observed crash.
actor VMLivenessMonitor {
    private let client: ClientContainerProtocol
    private let logger: Logger
    private let pollIntervalNs: UInt64
    private let probeTimeoutNs: UInt64
    private let failureThreshold: Int

    private var consecutiveFailures: [String: Int] = [:]
    private var loop: Task<Void, Never>?

    init(
        client: ClientContainerProtocol,
        logger: Logger,
        pollIntervalNs: UInt64 = 15_000_000_000,
        probeTimeoutNs: UInt64 = 5_000_000_000,
        failureThreshold: Int = 2
    ) {
        self.client = client
        self.logger = logger
        self.pollIntervalNs = pollIntervalNs
        self.probeTimeoutNs = probeTimeoutNs
        self.failureThreshold = failureThreshold
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(nanoseconds: self.pollIntervalNs)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func pollOnce() async {
        let running: [ContainerSnapshot]
        do {
            running = try await client.list(showAll: false, filters: [:])
        } catch {
            logger.warning("VMLivenessMonitor: failed to list running containers: \(error)")
            return
        }

        // Drop failure counts for containers no longer running (stopped/removed/died normally) —
        // otherwise a container that legitimately restarted would inherit a stale failure streak.
        let runningIds = Set(running.map(\.id))
        consecutiveFailures = consecutiveFailures.filter { runningIds.contains($0.key) }

        for container in running {
            await probe(id: container.id)
        }
    }

    private func probe(id: String) async {
        do {
            _ = try await withTimeout(nanoseconds: probeTimeoutNs) {
                try await ContainerClient().stats(id: id)
            }
            consecutiveFailures[id] = nil
        } catch {
            let failures = (consecutiveFailures[id] ?? 0) + 1
            guard failures >= failureThreshold else {
                consecutiveFailures[id] = failures
                logger.warning("VMLivenessMonitor: liveness probe failed for \(id) (\(failures)/\(failureThreshold)): \(error)")
                return
            }
            consecutiveFailures[id] = nil
            logger.error("VMLivenessMonitor: \(id) unresponsive after \(failures) consecutive probes — treating as dead")
            await declareDead(id: id)
        }
    }

    private func declareDead(id: String) async {
        await forceAppleRuntimeToNoticeDeath(id: id)
        await ContainerExitCodeStore.shared.set(id: id, code: ContainerExitCodeStore.waitFailureSentinel)
    }

    /// Apple's runtime won't transition a dead VM's internal state to stopped on its own — a
    /// later RestartPolicy bootstrap() would still find it marked "running" and silently no-op.
    /// Shares VMLifecycleAdmission with every other stop, since a host-wide contention event can
    /// mark several containers dead in the same window and firing all their forced stops at once
    /// would recreate the concurrent-teardown storm this project already fixed. Bypasses
    /// ClientContainerService.stop() deliberately — it would mark this "explicitly stopped" and
    /// suppress the RestartPolicy engagement that declareDead relies on.
    private func forceAppleRuntimeToNoticeDeath(id: String) async {
        do {
            try await VMLifecycleAdmission.shared.withSlot {
                try await ContainerClient().stop(id: id, opts: ContainerStopOptions(timeoutInSeconds: 1, signal: "SIGKILL"))
            }
        } catch {
            logger.debug("VMLivenessMonitor: stop while declaring \(id) dead errored as expected: \(error)")
        }
    }
}

struct LivenessProbeTimeout: Error {}

func withTimeout<T: Sendable>(nanoseconds: UInt64, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw LivenessProbeTimeout()
        }
        guard let result = try await group.next() else {
            throw LivenessProbeTimeout()
        }
        group.cancelAll()
        return result
    }
}
