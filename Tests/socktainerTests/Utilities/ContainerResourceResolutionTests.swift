import ContainerPersistence
import Foundation
import Testing

@testable import socktainer

/// Regression tests for socktainer#368.
///
/// A container created through the Docker API without explicit limits was sized
/// by `ContainerConfiguration`'s built-in defaults — a fixed 4 CPUs and 1 GiB —
/// so Apple Container's `[container] cpus` / `memory` had no effect on anything
/// created through socktainer, while `container run` honoured them. Only the
/// unset case was affected; `docker run -m … --cpus …` always worked.
///
/// Without the fix, every "falls back to the configured default" case below
/// returns nil and the container keeps the built-in 4 CPUs / 1 GiB.
@Suite("ContainerResourceResolution — [container] defaults (socktainer#368)")
struct ContainerResourceResolutionTests {

    /// Explicitly typed so the comparisons below cannot pick a different integer
    /// type for the literal — an untyped `4 * 1024 * 1024 * 1024` compared unequal
    /// to the `UInt64` result while printing the same number.
    private let fourGiB: UInt64 = 4 * 1024 * 1024 * 1024
    private let twoGiB: UInt64 = 2 * 1024 * 1024 * 1024

    private func configured(cpus: Int, memory: String) throws -> ContainerPersistence.ContainerConfig {
        ContainerPersistence.ContainerConfig(cpus: cpus, memory: try MemorySize(memory))
    }

    @Test("memory falls back to the configured [container] default when the request omits it")
    func memoryUsesConfiguredDefault() throws {
        let resolved = ContainerResourceResolution.memoryInBytes(
            requested: nil,
            configured: try configured(cpus: 6, memory: "4gb")
        )
        #expect(resolved == fourGiB)
    }

    @Test("cpus falls back to the configured [container] default when the request omits it")
    func cpusUsesConfiguredDefault() throws {
        let resolved = ContainerResourceResolution.cpus(
            requestedNanoCpus: nil,
            configured: try configured(cpus: 6, memory: "4gb")
        )
        #expect(resolved == 6)
    }

    @Test("an explicit memory request still wins over the configured default")
    func explicitMemoryWins() throws {
        let resolved = ContainerResourceResolution.memoryInBytes(
            requested: Int(twoGiB),
            configured: try configured(cpus: 6, memory: "4gb")
        )
        #expect(resolved == twoGiB)
    }

    @Test("an explicit cpu request still wins over the configured default")
    func explicitCpusWins() throws {
        let resolved = ContainerResourceResolution.cpus(
            requestedNanoCpus: 2_000_000_000,
            configured: try configured(cpus: 6, memory: "4gb")
        )
        #expect(resolved == 2)
    }

    @Test("a sub-1 CPU request is clamped to one vCPU, as before")
    func fractionalCpusClampToOne() throws {
        let resolved = ContainerResourceResolution.cpus(
            requestedNanoCpus: 500_000_000,
            configured: try configured(cpus: 6, memory: "4gb")
        )
        #expect(resolved == 1)
    }

    @Test("zero and negative requests are treated as absent, not as a limit")
    func nonPositiveRequestsFallBack() throws {
        let config = try configured(cpus: 6, memory: "4gb")
        #expect(ContainerResourceResolution.memoryInBytes(requested: 0, configured: config) == fourGiB)
        #expect(ContainerResourceResolution.memoryInBytes(requested: -1, configured: config) == fourGiB)
        #expect(ContainerResourceResolution.cpus(requestedNanoCpus: 0, configured: config) == 6)
        #expect(ContainerResourceResolution.cpus(requestedNanoCpus: -1, configured: config) == 6)
    }

    @Test("configuration left untouched when the defaults cannot be read")
    func noConfiguredDefaultsLeavesConfigurationAlone() {
        #expect(ContainerResourceResolution.memoryInBytes(requested: nil, configured: nil) == nil)
        #expect(ContainerResourceResolution.cpus(requestedNanoCpus: nil, configured: nil) == nil)
    }
}
