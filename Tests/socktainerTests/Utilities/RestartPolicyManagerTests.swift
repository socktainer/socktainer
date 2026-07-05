import Foundation
import Testing

@testable import socktainer

@Suite("RestartPolicyManager.decode")
struct RestartPolicyManagerDecodeTests {

    @Test("Decodes a persisted restart-policy label")
    func decodesLabel() {
        let policy = RestartPolicy(Name: "on-failure", MaximumRetryCount: 3)
        let json = String(data: try! JSONEncoder().encode(policy), encoding: .utf8)!
        let labels = [RestartPolicyManager.label: json]

        let decoded = RestartPolicyManager.decode(from: labels)
        #expect(decoded?.Name == "on-failure")
        #expect(decoded?.MaximumRetryCount == 3)
    }

    @Test("Returns nil when no label is present")
    func nilWhenAbsent() {
        #expect(RestartPolicyManager.decode(from: [:]) == nil)
    }
}

@Suite("RestartPolicyManager.shouldRestart")
struct RestartPolicyManagerShouldRestartTests {

    @Test("always restarts regardless of exit code")
    func alwaysRestarts() {
        let policy = RestartPolicy(Name: "always", MaximumRetryCount: nil)
        #expect(RestartPolicyManager.shouldRestart(policy: policy, exitCode: 0, attempt: 1))
        #expect(RestartPolicyManager.shouldRestart(policy: policy, exitCode: 1, attempt: 50))
    }

    @Test("unless-stopped restarts regardless of exit code")
    func unlessStoppedRestarts() {
        let policy = RestartPolicy(Name: "unless-stopped", MaximumRetryCount: nil)
        #expect(RestartPolicyManager.shouldRestart(policy: policy, exitCode: 0, attempt: 1))
    }

    @Test("on-failure does not restart on a clean exit")
    func onFailureSkipsCleanExit() {
        let policy = RestartPolicy(Name: "on-failure", MaximumRetryCount: nil)
        #expect(!RestartPolicyManager.shouldRestart(policy: policy, exitCode: 0, attempt: 1))
    }

    @Test("on-failure restarts on a non-zero exit, up to MaximumRetryCount")
    func onFailureRespectsMaxRetries() {
        let policy = RestartPolicy(Name: "on-failure", MaximumRetryCount: 2)
        #expect(RestartPolicyManager.shouldRestart(policy: policy, exitCode: 1, attempt: 1))
        #expect(RestartPolicyManager.shouldRestart(policy: policy, exitCode: 1, attempt: 2))
        #expect(!RestartPolicyManager.shouldRestart(policy: policy, exitCode: 1, attempt: 3))
    }

    @Test("on-failure with no MaximumRetryCount retries indefinitely")
    func onFailureUnboundedWithoutMax() {
        let policy = RestartPolicy(Name: "on-failure", MaximumRetryCount: nil)
        #expect(RestartPolicyManager.shouldRestart(policy: policy, exitCode: 1, attempt: 1000))
    }

    @Test("Unknown or 'no' policy names never restart")
    func unknownNamesNeverRestart() {
        #expect(!RestartPolicyManager.shouldRestart(policy: RestartPolicy(Name: "no", MaximumRetryCount: nil), exitCode: 1, attempt: 1))
        #expect(!RestartPolicyManager.shouldRestart(policy: RestartPolicy(Name: "", MaximumRetryCount: nil), exitCode: 1, attempt: 1))
        #expect(!RestartPolicyManager.shouldRestart(policy: RestartPolicy(Name: "bogus", MaximumRetryCount: nil), exitCode: 1, attempt: 1))
    }
}

@Suite("RestartPolicyManager.backoffDelayNanoseconds")
struct RestartPolicyManagerBackoffTests {

    @Test("Doubles per attempt and caps at 60 seconds")
    func doublesAndCaps() {
        let oneMs: UInt64 = 1_000_000
        #expect(RestartPolicyManager.backoffDelayNanoseconds(attempt: 1) == 100 * oneMs)
        #expect(RestartPolicyManager.backoffDelayNanoseconds(attempt: 2) == 200 * oneMs)
        #expect(RestartPolicyManager.backoffDelayNanoseconds(attempt: 3) == 400 * oneMs)
        #expect(RestartPolicyManager.backoffDelayNanoseconds(attempt: 100) == 60_000 * oneMs)
    }
}

@Suite("ContainerRestartState")
struct ContainerRestartStateTests {

    @Test("consumeExplicitlyStopped returns true once, then false")
    func consumeIsOneShot() async {
        let state = ContainerRestartState()
        await state.markExplicitlyStopped(id: "c1")
        #expect(await state.consumeExplicitlyStopped(id: "c1"))
        #expect(!(await state.consumeExplicitlyStopped(id: "c1")))
    }

    @Test("nextAttempt increments per container independently")
    func nextAttemptIncrements() async {
        let state = ContainerRestartState()
        #expect(await state.nextAttempt(id: "c1") == 1)
        #expect(await state.nextAttempt(id: "c1") == 2)
        #expect(await state.nextAttempt(id: "c2") == 1)
    }

    @Test("reset clears both explicitlyStopped and attempt count")
    func resetClearsState() async {
        let state = ContainerRestartState()
        await state.markExplicitlyStopped(id: "c1")
        _ = await state.nextAttempt(id: "c1")
        await state.reset(id: "c1")
        #expect(!(await state.consumeExplicitlyStopped(id: "c1")))
        #expect(await state.nextAttempt(id: "c1") == 1)
    }
}
