import ContainerPersistence
import Foundation
import Logging
import Testing

@testable import socktainer

/// Counts loads and lets a test hold them open, so concurrent callers overlap the load.
private actor LoadGate {
    private(set) var loads = 0
    private var failuresLeft: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false

    init(failures: Int = 0) {
        self.failuresLeft = failures
    }

    func load(_ config: ContainerPersistence.ContainerConfig) async throws -> ContainerPersistence.ContainerConfig {
        loads += 1
        if !open {
            await withCheckedContinuation { waiters.append($0) }
        }
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw CancellationError()
        }
        return config
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@Suite("ContainerResourceDefaults")
struct ContainerResourceDefaultsTests {
    private let logger = Logger(label: "test")

    private func configured() throws -> ContainerPersistence.ContainerConfig {
        ContainerPersistence.ContainerConfig(cpus: 6, memory: try MemorySize("4gb"))
    }

    // Three POST /containers/create in the same second: the callers that arrived while the
    // first load was in flight got nil and their containers the built-in 1 GiB.
    @Test("concurrent callers during the first load all get the configured defaults")
    func concurrentCallersShareTheLoad() async throws {
        let config = try configured()
        let gate = LoadGate()
        let defaults = ContainerResourceDefaults(load: { try await gate.load(config) })
        let logger = self.logger

        let results = await withTaskGroup(of: ContainerPersistence.ContainerConfig?.self) { group in
            for _ in 0..<5 {
                group.addTask { await defaults.current(logger: logger) }
            }
            // Let every caller reach the actor before the load completes.
            try? await Task.sleep(for: .milliseconds(100))
            await gate.release()
            var results: [ContainerPersistence.ContainerConfig?] = []
            for await result in group { results.append(result) }
            return results
        }

        #expect(results.count == 5)
        #expect(results.allSatisfy { $0?.cpus == 6 })
        #expect(await gate.loads == 1)
    }

    @Test("a successful load is cached")
    func successIsCached() async throws {
        let config = try configured()
        let gate = LoadGate()
        await gate.release()
        let defaults = ContainerResourceDefaults(load: { try await gate.load(config) })

        #expect(await defaults.current(logger: logger)?.cpus == 6)
        #expect(await defaults.current(logger: logger)?.cpus == 6)
        #expect(await gate.loads == 1)
    }

    @Test("a failed load is retried by the next caller")
    func failureIsRetried() async throws {
        let config = try configured()
        let gate = LoadGate(failures: 1)
        await gate.release()
        let defaults = ContainerResourceDefaults(load: { try await gate.load(config) })

        #expect(await defaults.current(logger: logger) == nil)
        #expect(await defaults.current(logger: logger)?.cpus == 6)
        #expect(await gate.loads == 2)
    }
}
