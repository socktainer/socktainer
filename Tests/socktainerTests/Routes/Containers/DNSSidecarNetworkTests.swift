import Testing

@testable import socktainer

@Suite("ContainerCreateRoute.dnsSidecarNetwork")
struct DNSSidecarNetworkTests {
    @Test("Without a configured upstream only named networks get a sidecar (unchanged)")
    func withoutUpstream() {
        #expect(
            ContainerCreateRoute.dnsSidecarNetwork(
                explicitNameservers: [], firstNamedNetwork: nil, primaryNetwork: "default", hasConfiguredUpstream: false) == nil)
        #expect(
            ContainerCreateRoute.dnsSidecarNetwork(
                explicitNameservers: [], firstNamedNetwork: "app", primaryNetwork: "app", hasConfiguredUpstream: false) == "app")
        // Today's behaviour: a sidecar replaces explicit nameservers on a named network.
        #expect(
            ContainerCreateRoute.dnsSidecarNetwork(
                explicitNameservers: ["1.1.1.1"], firstNamedNetwork: "app", primaryNetwork: "app", hasConfiguredUpstream: false) == "app")
    }

    @Test("With a configured upstream the default network gets a sidecar")
    func defaultNetworkWithUpstream() {
        #expect(
            ContainerCreateRoute.dnsSidecarNetwork(
                explicitNameservers: [], firstNamedNetwork: nil, primaryNetwork: "default", hasConfiguredUpstream: true) == "default")
    }

    @Test("With a configured upstream, named networks and other primary networks are unchanged")
    func namedNetworkWithUpstream() {
        #expect(
            ContainerCreateRoute.dnsSidecarNetwork(
                explicitNameservers: [], firstNamedNetwork: "app", primaryNetwork: "app", hasConfiguredUpstream: true) == "app")
        #expect(
            ContainerCreateRoute.dnsSidecarNetwork(
                explicitNameservers: [], firstNamedNetwork: nil, primaryNetwork: nil, hasConfiguredUpstream: true) == nil)
    }

    @Test("With a configured upstream an explicit HostConfig.Dns is kept")
    func explicitDnsKept() {
        #expect(
            ContainerCreateRoute.dnsSidecarNetwork(
                explicitNameservers: ["1.1.1.1"], firstNamedNetwork: nil, primaryNetwork: "default", hasConfiguredUpstream: true) == nil)
        #expect(
            ContainerCreateRoute.dnsSidecarNetwork(
                explicitNameservers: ["1.1.1.1"], firstNamedNetwork: "app", primaryNetwork: "app", hasConfiguredUpstream: true) == nil)
    }
}
