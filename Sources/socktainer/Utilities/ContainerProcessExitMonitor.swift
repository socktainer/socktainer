import Foundation

/// Watches a stopped-then-attached container's process to completion: resolves its exit
/// code (retrying past transient XPC throws), removes it from `ProcessRegistry`, waits out
/// the output-flush grace period, records the exit code under both ids, and performs
/// `--rm` auto-remove cleanup if it was marked for it. Shared by the HTTP and WS attach
/// routes' process-monitor tasks, which otherwise duplicated this identical sequence.
///
/// `wait` is injectable so the whole sequence — including the transient-throw retry and
/// dual-id recording — is testable without a live Apple Container process.
enum ContainerProcessExitMonitor {
    /// Grace period between the process exiting and recording its exit code.
    /// Lets pipe readers flush buffered output before other observers wake on the exit code.
    static let outputFlushGraceNs: UInt64 = 200_000_000  // 200ms

    static func run(
        wait: () async throws -> Int32,
        hexId: String,
        nativeId: String,
        fallbackImage: String,
        fallbackLabels: [String: String],
        dnsServer: SocktainerDNSServer?,
        broadcaster: EventBroadcaster?,
        /// Epoch of the run being watched, from `DieEventOwnership.beginRun` (or `currentEpoch`
        /// when attaching to a container this process did not start).
        runEpoch: Int,
        outputFlushGraceNs: UInt64 = ContainerProcessExitMonitor.outputFlushGraceNs,
        exitCodeRetryDelayNs: UInt64 = 100_000_000
    ) async -> Int32 {
        let code = await ContainerExitCodeStore.resolveExitCode(retryDelayNs: exitCodeRetryDelayNs, wait: wait)
        await ProcessRegistry.shared.remove(id: nativeId)

        // Claim before the flush grace: the start-route observer reserves the run when
        // `POST /start` returns, so claiming after a 200ms sleep would decide ownership by
        // timing rather than by who is responsible for the event. The claim names this
        // container's run, so a slow exit resolution cannot silence the next one.
        let ownsDieEvent: Bool
        if broadcaster != nil {
            ownsDieEvent = await DieEventOwnership.shared.claimForMonitor(id: nativeId, epoch: runEpoch)
        } else {
            ownsDieEvent = false
        }

        // Sleep before recording the code: lets this attachment's own output flush before
        // any die observer wakes and races ahead.
        try? await Task.sleep(nanoseconds: outputFlushGraceNs)
        await ContainerExitCodeStore.shared.set(id: nativeId, code: code)
        await ContainerExitCodeStore.shared.set(id: hexId, code: code)

        // Emit `die` when no start-route observer owns this exit. The attach route bootstraps
        // stopped containers, which is how `docker compose up` starts a service: it never calls
        // `POST /start`, so nothing else would ever report the exit and Compose's
        // --abort-on-container-exit would wait forever.
        //
        // The claim is deliberately not released after broadcasting: it stays held for the rest
        // of this run so a start-route observer arriving moments later cannot take it and emit
        // a second `die` for the same exit. The next run reopens it (`beginRun`).
        if let broadcaster, ownsDieEvent {
            var attributes = fallbackLabels
            attributes["exitCode"] = String(code)
            await broadcaster.broadcast(
                DockerEvent.simpleEvent(
                    id: hexId,
                    type: "container",
                    status: "die",
                    image: fallbackImage,
                    name: nativeId,
                    labels: attributes
                )
            )
        }

        // --rm: Apple Container reaps the container itself, so DELETE never arrives to
        // fire ContainerDeleteRoute's cleanup. consumeAutoRemove both gates on --rm and
        // dedups against a second observer racing the same exit.
        if await ContainerInfoCache.shared.consumeAutoRemove(id: hexId) {
            await ContainerAutoRemoveCleanup.perform(
                hexId: hexId,
                nativeId: nativeId,
                fallbackImage: fallbackImage,
                fallbackLabels: fallbackLabels,
                dnsServer: dnsServer,
                broadcaster: broadcaster
            )
        }
        return code
    }
}
