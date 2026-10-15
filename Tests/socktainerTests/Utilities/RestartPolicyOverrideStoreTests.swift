import Foundation
import Testing

@testable import socktainer

@Suite("RestartPolicyOverrideStore persistence")
struct RestartPolicyOverrideStoreTests {

    @Test("Started evidence and stop intent survive reloads and stop completion")
    func stopIntentSurvivesReload() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        try await store.recordStarted(id: "instance")
        // An already stopped native snapshot must not erase earlier start evidence.
        try await store.recordStopIntent(id: "instance", hasStarted: false)

        let reloaded = RestartPolicyOverrideStore()
        try await reloaded.configure(storageDirectory: directory)
        #expect(await reloaded.lifecycle(id: "instance") == RestartLifecycleRecord(hasStarted: true, manuallyStopped: true, pendingAction: .stop))
        try await reloaded.recordStopped(id: "instance")

        let completed = RestartPolicyOverrideStore()
        try await completed.configure(storageDirectory: directory)
        #expect(await completed.lifecycle(id: "instance") == RestartLifecycleRecord(hasStarted: true, manuallyStopped: true, pendingAction: nil))
    }

    @Test("A stop still in flight when a start completes survives it")
    func startDoesNotEraseInFlightStop() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        // A concurrent stop landed while the start awaited the runtime: the start
        // that raced it must not erase the user's intent.
        try await store.recordStopIntent(id: "instance", hasStarted: true)
        try await store.recordStarted(id: "instance")

        let reloaded = RestartPolicyOverrideStore()
        try await reloaded.configure(storageDirectory: directory)
        #expect(await reloaded.lifecycle(id: "instance") == RestartLifecycleRecord(hasStarted: true, manuallyStopped: true, pendingAction: .stop))
        // The same preservation holds for an automatic restart.
        try await reloaded.recordRestarted(id: "instance", attempt: 2)
        #expect(await reloaded.lifecycle(id: "instance")?.manuallyStopped == true)
        #expect(await reloaded.lifecycle(id: "instance")?.restartAttempts == 2)
    }

    @Test("A completed stop is superseded by a subsequent start")
    func startClearsCompletedStop() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        try await store.recordStopIntent(id: "instance", hasStarted: true)
        try await store.recordStopped(id: "instance")
        // A sequential stop-then-start begins a fresh lifecycle: the start intent
        // replaces the pending action, and the completed stop does not carry over.
        try await store.recordStartIntent(id: "instance")
        try await store.recordStarted(id: "instance")

        let reloaded = RestartPolicyOverrideStore()
        try await reloaded.configure(storageDirectory: directory)
        #expect(await reloaded.lifecycle(id: "instance") == RestartLifecycleRecord(hasStarted: true, manuallyStopped: false, pendingAction: nil))
    }

    @Test("Legacy overrides migrate without inventing lifecycle evidence")
    func migratesLegacyOverrides() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = ["instance": RestartPolicy(Name: "unless-stopped", MaximumRetryCount: nil)]
        try JSONEncoder().encode(legacy).write(to: storageFile(in: directory))

        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        #expect(await store.get(id: "instance")?.Name == "unless-stopped")
        #expect(await store.lifecycle(id: "instance") == nil)
        await store.set(id: "other-instance", policy: RestartPolicy(Name: "on-failure", MaximumRetryCount: 3))

        let data = try Data(contentsOf: storageFile(in: directory))
        let document = try JSONDecoder().decode(PersistedDocument.self, from: data)
        #expect(document.schemaVersion == 1)
        #expect(document.overrides["instance"]?.Name == "unless-stopped")
        #expect(document.lifecycles.isEmpty)

        let reloaded = RestartPolicyOverrideStore()
        try await reloaded.configure(storageDirectory: directory)
        #expect(await reloaded.lifecycle(id: "instance") == nil)
        #expect(await reloaded.get(id: "other-instance")?.MaximumRetryCount == 3)
        try await reloaded.recordStopIntent(id: "instance", hasStarted: false)
        #expect(await reloaded.lifecycle(id: "instance")?.hasStarted == false)
    }

    @Test("A recreated container's instance ID does not inherit old policy or lifecycle state")
    func isolatesInstanceIDs() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        await store.set(id: "old-instance", policy: RestartPolicy(Name: "always", MaximumRetryCount: nil))
        try await store.recordStopIntent(id: "old-instance", hasStarted: true)

        let reloaded = RestartPolicyOverrideStore()
        try await reloaded.configure(storageDirectory: directory)
        #expect(await reloaded.get(id: "new-instance") == nil)
        #expect(await reloaded.lifecycle(id: "new-instance") == nil)
        try await reloaded.recordStarted(id: "new-instance")
        #expect(await reloaded.lifecycle(id: "old-instance")?.manuallyStopped == true)
        #expect(await reloaded.lifecycle(id: "new-instance")?.manuallyStopped == false)
    }

    @Test("Pending starts preserve existing evidence and pending removals survive reload")
    func pendingActionsSurviveReload() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        try await store.recordStopIntent(id: "starting", hasStarted: true)
        try await store.recordStartIntent(id: "starting")
        try await store.recordStartIntent(id: "never-started")
        try await store.recordStarted(id: "removing")
        try await store.recordRemoveIntent(id: "removing")

        let reloaded = RestartPolicyOverrideStore()
        try await reloaded.configure(storageDirectory: directory)
        #expect(await reloaded.lifecycle(id: "starting") == RestartLifecycleRecord(hasStarted: true, manuallyStopped: true, pendingAction: .start))
        #expect(await reloaded.lifecycle(id: "never-started") == RestartLifecycleRecord(hasStarted: false, manuallyStopped: false, pendingAction: .start))
        #expect(await reloaded.lifecycle(id: "removing") == RestartLifecycleRecord(hasStarted: true, manuallyStopped: false, pendingAction: .remove))
    }

    @Test("Observed running confirms only pending starts and preserves stop or removal intent")
    func observedRunningPreservesUnfinishedStops() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        for id in ["starting", "stopping", "removing", "stopped"] {
            try await store.recordStopIntent(id: id, hasStarted: false)
        }
        try await store.recordStartIntent(id: "starting")
        try await store.recordRemoveIntent(id: "removing")
        try await store.recordStopped(id: "stopped")
        for id in ["starting", "stopping", "removing", "stopped", "unknown"] {
            try await store.recordObservedRunning(id: id)
        }

        let reloaded = RestartPolicyOverrideStore()
        try await reloaded.configure(storageDirectory: directory)
        #expect(await reloaded.lifecycle(id: "starting") == RestartLifecycleRecord(hasStarted: true, manuallyStopped: false, pendingAction: nil))
        #expect(await reloaded.lifecycle(id: "stopping") == RestartLifecycleRecord(hasStarted: true, manuallyStopped: true, pendingAction: .stop))
        #expect(await reloaded.lifecycle(id: "removing") == RestartLifecycleRecord(hasStarted: true, manuallyStopped: true, pendingAction: .remove))
        #expect(await reloaded.lifecycle(id: "stopped") == RestartLifecycleRecord(hasStarted: true, manuallyStopped: true, pendingAction: nil))
        #expect(await reloaded.lifecycle(id: "unknown") == RestartLifecycleRecord(hasStarted: true, manuallyStopped: false, pendingAction: nil, restartAttempts: nil))
    }

    @Test("Automatic restart reservations survive reload without resetting the retry budget")
    func restartBudgetSurvivesReload() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        try await store.recordStarted(id: "instance")
        try await store.recordRestartIntent(id: "instance", attempt: 2)
        let reloaded = RestartPolicyOverrideStore()
        try await reloaded.configure(storageDirectory: directory)
        #expect(await reloaded.lifecycle(id: "instance")?.restartAttempts == 2)
        #expect(await reloaded.lifecycle(id: "instance")?.pendingAction == .start)
        try await reloaded.recordObservedRunning(id: "instance")
        #expect(await reloaded.lifecycle(id: "instance")?.restartAttempts == 2)
        #expect(await reloaded.lifecycle(id: "instance")?.pendingAction == nil)
        try await reloaded.recordStarted(id: "instance")
        #expect(await reloaded.lifecycle(id: "instance")?.restartAttempts == 0)
    }

    @Test("A start intent preserves the retry budget until the start succeeds")
    func startIntentPreservesRetryBudget() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        try await store.recordStarted(id: "instance")
        try await store.recordRestarted(id: "instance", attempt: 2)
        // The intent precedes the runtime call: a start that fails — or a daemon
        // that dies mid-start — must not erase the budget previous runs earned.
        try await store.recordStartIntent(id: "instance")
        #expect(await store.lifecycle(id: "instance")?.restartAttempts == 2)
        #expect(await store.lifecycle(id: "instance")?.pendingAction == .start)
        // Only a successful start begins the new lifecycle that resets it.
        try await store.recordStarted(id: "instance")
        #expect(await store.lifecycle(id: "instance")?.restartAttempts == 0)
    }

    @Test("Older lifecycle documents do not invent a known retry count")
    func oldLifecycleHasUnknownBudget() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = #"{"schemaVersion":1,"overrides":{},"lifecycles":{"instance":{"hasStarted":true,"manuallyStopped":false}}}"#
        try Data(json.utf8).write(to: storageFile(in: directory))
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        #expect(await store.lifecycle(id: "instance")?.restartAttempts == nil)
    }

    @Test(
        "Invalid files fail configuration and cannot be overwritten by subsequent mutations",
        arguments: [
            "{broken-json",
            #"{"schemaVersion":2,"overrides":{},"lifecycles":{}}"#,
            #"{"schemaVersion":1,"overrides":{},"lifecycles":{"instance":{"hasStarted":true}}}"#,
        ]
    )
    func protectsInvalidFile(contents: String) async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data(contents.utf8)
        try original.write(to: storageFile(in: directory))
        let store = RestartPolicyOverrideStore()

        await #expect(throws: (any Error).self) {
            try await store.configure(storageDirectory: directory)
        }
        // Policy overrides log-and-continue (their callers cannot react to a disk
        // failure); lifecycle mutations still surface the error.
        await store.set(id: "instance", policy: RestartPolicy(Name: "always", MaximumRetryCount: nil))
        await #expect(throws: (any Error).self) {
            try await store.recordStarted(id: "instance")
        }
        await store.remove(id: "instance")

        #expect(await store.get(id: "instance") == nil)
        #expect(await store.lifecycle(id: "instance") == nil)
        #expect(try Data(contentsOf: storageFile(in: directory)) == original)
    }

    @Test("Failed writes leave both the policy and lifecycle memory unchanged")
    func failedWritesPreserveMemory() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        await store.set(id: "instance", policy: RestartPolicy(Name: "always", MaximumRetryCount: nil))
        try await store.recordStarted(id: "instance")
        let originalLifecycle = await store.lifecycle(id: "instance")

        // A directory at the destination makes atomic replacement fail even when
        // tests run as a user that can bypass ordinary permission restrictions.
        let file = storageFile(in: directory)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        // Policy overrides log-and-continue; the lifecycle mutation throws.
        await store.set(id: "instance", policy: RestartPolicy(Name: "no", MaximumRetryCount: nil))
        await #expect(throws: (any Error).self) {
            try await store.recordStopIntent(id: "instance", hasStarted: true)
        }
        await store.remove(id: "instance")
        #expect(await store.get(id: "instance")?.Name == "always")
        #expect(await store.lifecycle(id: "instance") == originalLifecycle)
    }

    @Test("Remove clears policy and lifecycle together, including lifecycle-only records")
    func removeClearsBothKindsOfState() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        await store.set(id: "instance", policy: RestartPolicy(Name: "always", MaximumRetryCount: nil))
        try await store.recordStarted(id: "instance")
        try await store.recordStarted(id: "lifecycle-only")
        try await store.recordStarted(id: "retained")
        await store.remove(id: "instance")
        await store.remove(id: "lifecycle-only")

        let reloaded = RestartPolicyOverrideStore()
        try await reloaded.configure(storageDirectory: directory)
        #expect(await reloaded.get(id: "instance") == nil)
        #expect(await reloaded.lifecycle(id: "instance") == nil)
        #expect(await reloaded.lifecycle(id: "lifecycle-only") == nil)
        #expect(await reloaded.lifecycle(id: "retained")?.hasStarted == true)
    }

    @Test("Concurrent mutations retain every container's policy and start evidence")
    func concurrentMutationsDoNotLoseUpdates() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let id = "instance-\(index)"
                    await store.set(id: id, policy: RestartPolicy(Name: "always", MaximumRetryCount: nil))
                    try await store.recordStarted(id: id)
                }
            }
            try await group.waitForAll()
        }

        let reloaded = RestartPolicyOverrideStore()
        try await reloaded.configure(storageDirectory: directory)
        for index in 0..<20 {
            let id = "instance-\(index)"
            #expect(await reloaded.get(id: id)?.Name == "always")
            #expect(await reloaded.lifecycle(id: id)?.hasStarted == true)
        }
    }

    @Test("Unconfigured isolated stores retain the in-memory testing mode")
    func supportsInMemoryStores() async throws {
        let store = RestartPolicyOverrideStore()
        await store.set(id: "instance", policy: RestartPolicy(Name: "always", MaximumRetryCount: nil))
        try await store.recordStarted(id: "instance")
        #expect(await store.get(id: "instance")?.Name == "always")
        #expect(await store.lifecycle(id: "instance")?.hasStarted == true)
        await store.remove(id: "instance")
        #expect(await store.get(id: "instance") == nil)
        #expect(await store.lifecycle(id: "instance") == nil)
    }

    @Test("A committed real exit code survives reloads and a new run clears it")
    func exitFactSurvivesReloadAndClearsOnNewRun() async throws {
        let directory = try makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RestartPolicyOverrideStore()
        try await store.configure(storageDirectory: directory)
        try await store.recordStarted(id: "instance")
        try await store.recordStopIntent(id: "instance", hasStarted: true)
        // The exit happens after the stop intent: both facts must stand together.
        try await store.recordExit(id: "instance", code: 7)

        let reloaded = RestartPolicyOverrideStore()
        try await reloaded.configure(storageDirectory: directory)
        #expect(
            await reloaded.lifecycle(id: "instance")
                == RestartLifecycleRecord(
                    hasStarted: true, manuallyStopped: true, pendingAction: .stop, restartAttempts: 0, lastExitCode: 7))

        // A new run begins: the previous run's code no longer describes this instance.
        try await reloaded.recordStarted(id: "instance")
        #expect(await reloaded.lifecycle(id: "instance")?.lastExitCode == nil)

        let afterStart = RestartPolicyOverrideStore()
        try await afterStart.configure(storageDirectory: directory)
        #expect(await afterStart.lifecycle(id: "instance")?.lastExitCode == nil)
    }

    @Test("Observing a running instance clears the previous run's exit code")
    func observedRunningClearsStaleExit() async throws {
        let store = RestartPolicyOverrideStore()
        try await store.recordStarted(id: "instance")
        try await store.recordExit(id: "instance", code: 7)
        try await store.recordObservedRunning(id: "instance")
        #expect(await store.lifecycle(id: "instance")?.lastExitCode == nil)
        #expect(await store.lifecycle(id: "instance")?.hasStarted == true)
    }

    @Test("An exit code for an unmanaged instance creates no lifecycle record")
    func exitForUnmanagedInstanceIsIgnored() async throws {
        let store = RestartPolicyOverrideStore()
        try await store.recordExit(id: "unmanaged", code: 7)
        #expect(await store.lifecycle(id: "unmanaged") == nil)
    }

    private struct PersistedDocument: Decodable {
        let schemaVersion: Int
        let overrides: [String: RestartPolicy]
        let lifecycles: [String: RestartLifecycleRecord]
    }

    private func makeStorageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("restart-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func storageFile(in directory: URL) -> URL {
        directory.appendingPathComponent("socktainer-restart-policy-overrides.json")
    }
}
