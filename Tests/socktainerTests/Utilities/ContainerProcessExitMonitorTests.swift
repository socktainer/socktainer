import Testing

@testable import socktainer

/// Regression tests for issue #258's DoD item: attach-WS (and the HTTP attach route, which
/// shares this exact sequence) must persist only an observed exit code, never a synthetic
/// value, when the wait() XPC round-trip throws transiently. `wait` is injectable so this is
/// verified end to end — retry, dual-id recording, and auto-remove dispatch — without a live
/// Apple Container process.
@Suite("ContainerProcessExitMonitor")
struct ContainerProcessExitMonitorTests {

    @Test("a transient wait() throw does not surface as a synthetic exit code under either id")
    func transientThrowStillRecordsTheObservedCode() async {
        let hexId = "hex-\(Int.random(in: 100000...999999))"
        let nativeId = "native-\(Int.random(in: 100000...999999))"
        var calls = 0

        let code = await ContainerProcessExitMonitor.run(
            wait: {
                calls += 1
                if calls < 3 { throw TransientWaitError() }
                return 7
            },
            hexId: hexId,
            nativeId: nativeId,
            fallbackImage: "alpine:latest",
            fallbackLabels: [:],
            dnsServer: nil,
            broadcaster: nil,
            outputFlushGraceNs: 0,
            exitCodeRetryDelayNs: 0
        )

        #expect(code == 7, "the retried, authoritative code must be returned, not a synthetic -1")
        #expect(calls == 3)
        #expect(await ContainerExitCodeStore.shared.get(id: nativeId) == 7)
        #expect(await ContainerExitCodeStore.shared.get(id: hexId) == 7)

        await ContainerExitCodeStore.shared.remove(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: hexId)
    }

    @Test("wait() failing on every attempt records the failure sentinel, not exit code 0")
    func persistentFailureRecordsSentinelNotZero() async {
        let hexId = "hex-\(Int.random(in: 100000...999999))"
        let nativeId = "native-\(Int.random(in: 100000...999999))"

        let code = await ContainerProcessExitMonitor.run(
            wait: { throw TransientWaitError() },
            hexId: hexId,
            nativeId: nativeId,
            fallbackImage: "alpine:latest",
            fallbackLabels: [:],
            dnsServer: nil,
            broadcaster: nil,
            outputFlushGraceNs: 0,
            exitCodeRetryDelayNs: 0
        )

        #expect(code == ContainerExitCodeStore.waitFailureSentinel)
        #expect(await ContainerExitCodeStore.shared.get(id: nativeId) == ContainerExitCodeStore.waitFailureSentinel)
        #expect(await ContainerExitCodeStore.shared.get(id: hexId) == ContainerExitCodeStore.waitFailureSentinel)

        await ContainerExitCodeStore.shared.remove(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: hexId)
    }

    @Test("a --rm container marked for auto-remove is cleaned up after exit")
    func autoRemoveMarkedContainerIsCleanedUp() async {
        let hexId = "hex-\(Int.random(in: 100000...999999))"
        let nativeId = "native-\(Int.random(in: 100000...999999))"
        await ContainerInfoCache.shared.set(hexId: hexId, nativeId: nativeId, image: "alpine:latest", labels: [:], ip: nil)
        await ContainerInfoCache.shared.markAutoRemove(hexId: hexId, nativeId: nativeId)

        _ = await ContainerProcessExitMonitor.run(
            wait: { 0 },
            hexId: hexId,
            nativeId: nativeId,
            fallbackImage: "alpine:latest",
            fallbackLabels: [:],
            dnsServer: nil,
            broadcaster: nil,
            outputFlushGraceNs: 0,
            exitCodeRetryDelayNs: 0
        )

        #expect(await ContainerInfoCache.shared.get(id: nativeId) == nil, "the cache entry must be cleared once auto-remove cleanup runs")

        await ContainerExitCodeStore.shared.remove(id: nativeId)
        await ContainerExitCodeStore.shared.remove(id: hexId)
    }
}

private struct TransientWaitError: Error {}
