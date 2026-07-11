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
        #expect(RestartPolicyManager.shouldRestart(policy: policy, exitCode: 0, attempt: 1, hasBeenManuallyStopped: false))
        #expect(RestartPolicyManager.shouldRestart(policy: policy, exitCode: 1, attempt: 50, hasBeenManuallyStopped: false))
    }

    @Test("a manual stop suppresses every policy, like moby's restart-manager cancel")
    func manualStopSuppressesEveryPolicy() {
        for name in ["always", "unless-stopped", "on-failure"] {
            let policy = RestartPolicy(Name: name, MaximumRetryCount: nil)
            #expect(!RestartPolicyManager.shouldRestart(policy: policy, exitCode: 1, attempt: 1, hasBeenManuallyStopped: true), Comment(rawValue: name))
        }
    }

    @Test("unless-stopped restarts regardless of exit code when not manually stopped")
    func unlessStoppedRestarts() {
        let policy = RestartPolicy(Name: "unless-stopped", MaximumRetryCount: nil)
        #expect(RestartPolicyManager.shouldRestart(policy: policy, exitCode: 0, attempt: 1, hasBeenManuallyStopped: false))
    }

    @Test("unless-stopped does not restart after an explicit stop/kill")
    func unlessStoppedHonorsManualStop() {
        let policy = RestartPolicy(Name: "unless-stopped", MaximumRetryCount: nil)
        #expect(!RestartPolicyManager.shouldRestart(policy: policy, exitCode: 0, attempt: 1, hasBeenManuallyStopped: true))
    }

    @Test("on-failure does not restart on a clean exit")
    func onFailureSkipsCleanExit() {
        let policy = RestartPolicy(Name: "on-failure", MaximumRetryCount: nil)
        #expect(!RestartPolicyManager.shouldRestart(policy: policy, exitCode: 0, attempt: 1, hasBeenManuallyStopped: false))
    }

    @Test("on-failure restarts on a non-zero exit, up to MaximumRetryCount")
    func onFailureRespectsMaxRetries() {
        let policy = RestartPolicy(Name: "on-failure", MaximumRetryCount: 2)
        #expect(RestartPolicyManager.shouldRestart(policy: policy, exitCode: 1, attempt: 1, hasBeenManuallyStopped: false))
        #expect(RestartPolicyManager.shouldRestart(policy: policy, exitCode: 1, attempt: 2, hasBeenManuallyStopped: false))
        #expect(!RestartPolicyManager.shouldRestart(policy: policy, exitCode: 1, attempt: 3, hasBeenManuallyStopped: false))
    }

    @Test("on-failure with no MaximumRetryCount retries indefinitely")
    func onFailureUnboundedWithoutMax() {
        let policy = RestartPolicy(Name: "on-failure", MaximumRetryCount: nil)
        #expect(RestartPolicyManager.shouldRestart(policy: policy, exitCode: 1, attempt: 1000, hasBeenManuallyStopped: false))
    }

    @Test("Unknown or 'no' policy names never restart")
    func unknownNamesNeverRestart() {
        #expect(!RestartPolicyManager.shouldRestart(policy: RestartPolicy(Name: "no", MaximumRetryCount: nil), exitCode: 1, attempt: 1, hasBeenManuallyStopped: false))
        #expect(!RestartPolicyManager.shouldRestart(policy: RestartPolicy(Name: "", MaximumRetryCount: nil), exitCode: 1, attempt: 1, hasBeenManuallyStopped: false))
        #expect(!RestartPolicyManager.shouldRestart(policy: RestartPolicy(Name: "bogus", MaximumRetryCount: nil), exitCode: 1, attempt: 1, hasBeenManuallyStopped: false))
    }
}

@Suite("RestartPolicyManager.nextBackoffMillis")
struct RestartPolicyManagerBackoffTests {

    @Test("Doubles per rapid successive crash and caps at 60 seconds")
    func doublesAndCaps() {
        var current: UInt64 = 0
        for expected: UInt64 in [100, 200, 400, 800, 1600] {
            current = RestartPolicyManager.nextBackoffMillis(current: current, ranAtLeast10Seconds: false)
            #expect(current == expected)
        }
        // Keep doubling well past the cap to confirm it clamps rather than overflowing.
        for _ in 0..<20 {
            current = RestartPolicyManager.nextBackoffMillis(current: current, ranAtLeast10Seconds: false)
        }
        #expect(current == 60_000)
    }

    @Test("Resets to the 100ms base once the container ran at least 10 seconds, matching moby")
    func resetsAfterHealthyRuntime() {
        var current: UInt64 = 60_000
        current = RestartPolicyManager.nextBackoffMillis(current: current, ranAtLeast10Seconds: true)
        #expect(current == 100)
    }
}

@Suite("RestartPolicyManager.validate")
struct RestartPolicyManagerValidateTests {

    private func hostConfig(_ json: String) -> HostConfig {
        try! JSONDecoder().decode(HostConfig.self, from: Data(json.utf8))
    }

    @Test("No HostConfig is valid")
    func nilHostConfigIsValid() {
        #expect(RestartPolicyManager.validate(hostConfig: nil) == nil)
    }

    @Test("No RestartPolicy is valid")
    func nilRestartPolicyIsValid() {
        #expect(RestartPolicyManager.validate(hostConfig: hostConfig(#"{}"#)) == nil)
    }

    @Test("Known policy names without a retry count are valid")
    func knownNamesAreValid() {
        for name in ["no", "always", "unless-stopped", "on-failure"] {
            #expect(RestartPolicyManager.validate(hostConfig: hostConfig(#"{"RestartPolicy":{"Name":"\#(name)"}}"#)) == nil)
        }
    }

    @Test("An unknown policy name is rejected, matching moby")
    func unknownNameRejected() {
        let error = RestartPolicyManager.validate(hostConfig: hostConfig(#"{"RestartPolicy":{"Name":"bogus"}}"#))
        #expect(error == "invalid restart policy: unknown policy 'bogus'; use one of 'no', 'always', 'on-failure', or 'unless-stopped'")
    }

    @Test("A MaximumRetryCount on a non-'on-failure' policy is rejected, matching moby")
    func retryCountOnNonOnFailureRejected() {
        let error = RestartPolicyManager.validate(hostConfig: hostConfig(#"{"RestartPolicy":{"Name":"always","MaximumRetryCount":3}}"#))
        #expect(error == "invalid restart policy: maximum retry count can only be used with 'on-failure'")
    }

    @Test("A negative MaximumRetryCount on a non-'on-failure' policy mentions both reasons, matching moby")
    func negativeRetryCountOnNonOnFailureRejected() {
        let error = RestartPolicyManager.validate(hostConfig: hostConfig(#"{"RestartPolicy":{"Name":"no","MaximumRetryCount":-1}}"#))
        #expect(error == "invalid restart policy: maximum retry count can only be used with 'on-failure' and cannot be negative")
    }

    @Test("A negative MaximumRetryCount on 'on-failure' is rejected, matching moby")
    func negativeRetryCountOnOnFailureRejected() {
        let error = RestartPolicyManager.validate(hostConfig: hostConfig(#"{"RestartPolicy":{"Name":"on-failure","MaximumRetryCount":-1}}"#))
        #expect(error == "invalid restart policy: maximum retry count cannot be negative")
    }

    @Test("A non-negative MaximumRetryCount on 'on-failure' is valid")
    func nonNegativeRetryCountOnOnFailureValid() {
        #expect(RestartPolicyManager.validate(hostConfig: hostConfig(#"{"RestartPolicy":{"Name":"on-failure","MaximumRetryCount":5}}"#)) == nil)
    }

    @Test("AutoRemove with a non-'no' restart policy is rejected, matching moby")
    func autoRemoveWithRestartPolicyRejected() {
        let error = RestartPolicyManager.validate(hostConfig: hostConfig(#"{"RestartPolicy":{"Name":"always"},"AutoRemove":true}"#))
        #expect(error == "can't create 'AutoRemove' container with restart policy")
    }

    @Test("AutoRemove with a 'no' restart policy is valid")
    func autoRemoveWithNoRestartPolicyValid() {
        #expect(RestartPolicyManager.validate(hostConfig: hostConfig(#"{"RestartPolicy":{"Name":"no"},"AutoRemove":true}"#)) == nil)
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

    @Test("reset clears explicitlyStopped, attempt count, pending-restart, and backoff state")
    func resetClearsState() async {
        let state = ContainerRestartState()
        await state.markExplicitlyStopped(id: "c1")
        _ = await state.nextAttempt(id: "c1")
        await state.markPendingRestart(id: "c1")
        _ = await state.nextBackoffDelayNanoseconds(id: "c1", ranAtLeast10Seconds: false)
        await state.reset(id: "c1")
        #expect(!(await state.consumeExplicitlyStopped(id: "c1")))
        #expect(await state.nextAttempt(id: "c1") == 1)
        #expect(!(await state.isPendingRestart(id: "c1")))
        #expect(await state.nextBackoffDelayNanoseconds(id: "c1", ranAtLeast10Seconds: false) == 100 * 1_000_000)
    }

    @Test("reset bumps the generation token, independently per container")
    func resetBumpsGeneration() async {
        let state = ContainerRestartState()
        #expect(await state.currentGeneration(id: "c1") == 0)
        await state.reset(id: "c1")
        #expect(await state.currentGeneration(id: "c1") == 1)
        await state.reset(id: "c1")
        #expect(await state.currentGeneration(id: "c1") == 2)
        #expect(await state.currentGeneration(id: "c2") == 0)
    }

    @Test("count reports the current attempt tally without mutating it")
    func countReportsWithoutMutating() async {
        let state = ContainerRestartState()
        #expect(await state.count(id: "c1") == 0)
        _ = await state.nextAttempt(id: "c1")
        _ = await state.nextAttempt(id: "c1")
        #expect(await state.count(id: "c1") == 2)
        #expect(await state.count(id: "c1") == 2)
    }

    @Test("pending-restart is tracked and cleared independently per container")
    func pendingRestartTracking() async {
        let state = ContainerRestartState()
        #expect(!(await state.isPendingRestart(id: "c1")))
        await state.markPendingRestart(id: "c1")
        #expect(await state.isPendingRestart(id: "c1"))
        #expect(!(await state.isPendingRestart(id: "c2")))
        await state.clearPendingRestart(id: "c1")
        #expect(!(await state.isPendingRestart(id: "c1")))
    }

    @Test("nextBackoffDelayNanoseconds doubles across successive calls, tracked independently per container")
    func backoffDoublesAcrossCallsPerContainer() async {
        let state = ContainerRestartState()
        let oneMs: UInt64 = 1_000_000
        #expect(await state.nextBackoffDelayNanoseconds(id: "c1", ranAtLeast10Seconds: false) == 100 * oneMs)
        #expect(await state.nextBackoffDelayNanoseconds(id: "c1", ranAtLeast10Seconds: false) == 200 * oneMs)
        #expect(await state.nextBackoffDelayNanoseconds(id: "c1", ranAtLeast10Seconds: false) == 400 * oneMs)
        // A second container's backoff is independent of the first's.
        #expect(await state.nextBackoffDelayNanoseconds(id: "c2", ranAtLeast10Seconds: false) == 100 * oneMs)
    }

    @Test("nextBackoffDelayNanoseconds resets after a healthy run, matching moby")
    func backoffResetsAfterHealthyRuntime() async {
        let state = ContainerRestartState()
        let oneMs: UInt64 = 1_000_000
        _ = await state.nextBackoffDelayNanoseconds(id: "c1", ranAtLeast10Seconds: false)
        _ = await state.nextBackoffDelayNanoseconds(id: "c1", ranAtLeast10Seconds: false)
        #expect(await state.nextBackoffDelayNanoseconds(id: "c1", ranAtLeast10Seconds: true) == 100 * oneMs)
    }
}
