import Foundation
import Testing

@testable import socktainer

private actor RelayRecoveryFixture {
    enum ExpectedFailure: Error { case exhausted }

    private var statuses: [PortRelayProtocol.ConnectStatus]
    private(set) var creations = 0
    private(set) var replacements = 0
    private(set) var probes = 0

    init(statuses: [PortRelayProtocol.ConnectStatus]) {
        self.statuses = statuses
    }

    func createOrAdopt() -> String {
        creations += 1
        return "/tmp/relay-\(creations).sock"
    }

    func replace() { replacements += 1 }

    func probe(_ socket: String) throws -> PortRelayProtocol.ConnectStatus {
        probes += 1
        guard !statuses.isEmpty else { throw ExpectedFailure.exhausted }
        return statuses.removeFirst()
    }

    func counts() -> (creations: Int, replacements: Int, probes: Int) {
        (creations, replacements, probes)
    }
}

@Suite("Network relay route recovery")
struct NetworkRelayRecoveryTests {
    @Test("route failure replaces the relay once and accepts the recovered route")
    func replacesBrokenRoute() async throws {
        let fixture = RelayRecoveryFixture(
            statuses: Array(repeating: .routeUnavailable, count: 5) + [.ready]
        )

        let socket = try await NetworkRelayManager.checkedRelayForTesting(
            createOrAdopt: { await fixture.createOrAdopt() },
            replace: { await fixture.replace() },
            probe: { try await fixture.probe($0) }
        )

        #expect(socket == "/tmp/relay-2.sock")
        let counts = await fixture.counts()
        #expect(counts.creations == 2)
        #expect(counts.replacements == 1)
        #expect(counts.probes == 6)
    }

    @Test("transient route failure recovers without replacing the relay")
    func transientFailureIsRetried() async throws {
        let fixture = RelayRecoveryFixture(
            statuses: [.routeUnavailable, .routeUnavailable, .ready]
        )

        let socket = try await NetworkRelayManager.checkedRelayForTesting(
            createOrAdopt: { await fixture.createOrAdopt() },
            replace: { await fixture.replace() },
            probe: { try await fixture.probe($0) }
        )

        #expect(socket == "/tmp/relay-1.sock")
        let counts = await fixture.counts()
        #expect(counts.creations == 1)
        #expect(counts.replacements == 0)
        #expect(counts.probes == 3)
    }

    @Test("persistent route failure is bounded to one replacement")
    func persistentFailureIsBounded() async {
        let fixture = RelayRecoveryFixture(
            statuses: Array(repeating: .routeUnavailable, count: 10)
        )

        await #expect(throws: (any Error).self) {
            _ = try await NetworkRelayManager.checkedRelayForTesting(
                createOrAdopt: { await fixture.createOrAdopt() },
                replace: { await fixture.replace() },
                probe: { try await fixture.probe($0) }
            )
        }
        let counts = await fixture.counts()
        #expect(counts.creations == 2)
        #expect(counts.replacements == 1)
        #expect(counts.probes == 10)
    }

    @Test(
        "target refusal and timeout preserve the relay while an application starts"
    )
    func targetLifecycleDoesNotReplaceRelay() async throws {
        for status in [
            PortRelayProtocol.ConnectStatus.connectionRefused,
            .timedOut,
        ] {
            let fixture = RelayRecoveryFixture(statuses: [status])
            let socket = try await NetworkRelayManager.checkedRelayForTesting(
                createOrAdopt: { await fixture.createOrAdopt() },
                replace: { await fixture.replace() },
                probe: { try await fixture.probe($0) }
            )
            #expect(socket == "/tmp/relay-1.sock")
            let counts = await fixture.counts()
            #expect(counts.creations == 1)
            #expect(counts.replacements == 0)
        }
    }

    @Test("policy and protocol failures fail without replacement churn")
    func explicitFailuresDoNotChurn() async {
        for status in [
            PortRelayProtocol.ConnectStatus.denied,
            .failed,
        ] {
            let fixture = RelayRecoveryFixture(statuses: [status])
            await #expect(throws: (any Error).self) {
                _ = try await NetworkRelayManager.checkedRelayForTesting(
                    createOrAdopt: { await fixture.createOrAdopt() },
                    replace: { await fixture.replace() },
                    probe: { try await fixture.probe($0) }
                )
            }
            let counts = await fixture.counts()
            #expect(counts.creations == 1)
            #expect(counts.replacements == 0)
        }
    }
}
