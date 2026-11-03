import Testing

@testable import socktainer

/// `POST /build` may create and start the QEMU builder right before its reachability check, and
/// starting it does not wait for BuildKit's socket. Three seconds was too short for that cold
/// start, so the route returned 503 for a builder that was still coming up.
@Suite("BuildRoute builder reachability timeout")
struct BuildReachabilityTimeoutTests {
    @Test("a QEMU builder gets more than three seconds to become reachable")
    func qemuBuilderGetsLongerTimeout() {
        #expect(BuildRoute.builderReachabilityTimeout(qemu: true) > .seconds(3))
        #expect(BuildRoute.builderReachabilityTimeout(qemu: true) > BuildRoute.builderReachabilityTimeout(qemu: false))
    }

    @Test("the Rosetta builder keeps its three-second timeout")
    func rosettaBuilderTimeoutUnchanged() {
        #expect(BuildRoute.builderReachabilityTimeout(qemu: false) == .seconds(3))
    }
}
