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
    static func run(
        wait: () async throws -> Int32,
        hexId: String,
        nativeId: String,
        fallbackImage: String,
        fallbackLabels: [String: String],
        dnsServer: SocktainerDNSServer?,
        broadcaster: EventBroadcaster?,
        outputFlushGraceNs: UInt64 = ContainerAttachRoute.outputFlushGraceNs,
        exitCodeRetryDelayNs: UInt64 = 100_000_000
    ) async -> Int32 {
        let code = await ContainerExitCodeStore.resolveExitCode(retryDelayNs: exitCodeRetryDelayNs, wait: wait)
        await ProcessRegistry.shared.remove(id: nativeId)

        // Sleep before recording the code: lets this attachment's own output flush before
        // any die observer wakes and races ahead.
        try? await Task.sleep(nanoseconds: outputFlushGraceNs)
        await ContainerExitCodeStore.shared.set(id: nativeId, code: code)
        await ContainerExitCodeStore.shared.set(id: hexId, code: code)

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
