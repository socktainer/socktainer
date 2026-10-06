import Testing

@testable import socktainer

/// Regression tests for issue #258: the `--rm` auto-remove paths (start, attach, attach-WS)
/// only unregistered a container's primary name, leaving `socktainer.dns.names` and Compose
/// service/project aliases pointing at a deleted container's IP.
@Suite("ContainerAliasCleanup")
struct ContainerAliasCleanupTests {

    @Test("unregisters the container's own name, custom aliases, and compose service/project aliases")
    func unregistersFullAliasSet() {
        let dnsServer = SocktainerDNSServer()
        dnsServer.register(hostname: "web-1", ip: "10.0.0.5")
        dnsServer.register(hostname: "api", ip: "10.0.0.5")
        dnsServer.register(hostname: "web", ip: "10.0.0.5")
        dnsServer.register(hostname: "web.myapp", ip: "10.0.0.5")

        ContainerAliasCleanup.unregisterAllAliases(
            nativeId: "web-1",
            labels: [
                "socktainer.dns.names": "api",
                "com.docker.compose.service": "web",
                "com.docker.compose.project": "myapp",
            ],
            cachedIP: "10.0.0.5",
            dnsServer: dnsServer
        )

        let remaining = dnsServer.listEntries()
        #expect(remaining["web-1"] == nil)
        #expect(remaining["api"] == nil)
        #expect(remaining["web"] == nil)
        #expect(remaining["web.myapp"] == nil)
    }

    @Test("does not touch any alias when cachedIP is nil — ownership can't be confirmed")
    func skipsAllAliasesWhenCachedIPIsNil() {
        let dnsServer = SocktainerDNSServer()
        dnsServer.register(hostname: "db", ip: "10.0.0.9")

        ContainerAliasCleanup.unregisterAllAliases(
            nativeId: "db",
            labels: ["com.docker.compose.service": "db"],
            cachedIP: nil,
            dnsServer: dnsServer
        )

        #expect(dnsServer.listEntries()["db"] == "10.0.0.9")
    }

    @Test("does not unregister an alias now owned by a different, live container")
    func leavesLiveOwnersAliasIntact() {
        let dnsServer = SocktainerDNSServer()
        // A second "db" service (different Compose project) has since registered the same
        // alias with its own IP. The dying container's cachedIP no longer matches.
        dnsServer.register(hostname: "db", ip: "10.0.0.20")

        ContainerAliasCleanup.unregisterAllAliases(
            nativeId: "db-old",
            labels: ["com.docker.compose.service": "db"],
            cachedIP: "10.0.0.9",
            dnsServer: dnsServer
        )

        #expect(dnsServer.listEntries()["db"] == "10.0.0.20")
    }

    @Test("unregistering an alias that isn't registered is a no-op")
    func unregisteredAliasIsNoOp() {
        let dnsServer = SocktainerDNSServer()

        ContainerAliasCleanup.unregisterAllAliases(
            nativeId: "ghost",
            labels: [:],
            cachedIP: "10.0.0.5",
            dnsServer: dnsServer
        )

        #expect(dnsServer.listEntries().isEmpty)
    }
}
