import Testing

@testable import socktainer

@Suite("NetworkAliasDNS")
struct NetworkAliasDNSTests {

    /// A distinct attachment hostname for the `myapp_default` fixtures below.
    let explicitHostname = "host.myapp_default.test"
    /// The container name, and the attachment hostname it produces by default.
    let name = "c1"
    let hostname = "c1.myapp_default.test"

    // MARK: - isReservedNetwork

    @Test("reserved network names are recognized case-insensitively")
    func reservedNetworks() {
        for name in ["default", "bridge", "host", "none", "DEFAULT", "Bridge"] {
            #expect(NetworkAliasDNS.isReservedNetwork(name), "\(name)")
        }
    }

    @Test("user-defined networks are not reserved")
    func nonReservedNetwork() {
        #expect(!NetworkAliasDNS.isReservedNetwork("mynet"))
        #expect(!NetworkAliasDNS.isReservedNetwork("myapp_default"))
    }

    // MARK: - zone

    @Test("the zone is the network name and the domain, with the network lowercased")
    func zoneUsesTheNetworkName() {
        #expect(NetworkAliasDNS.zone("myapp_default", dnsDomain: "test") == "myapp_default.test")
        #expect(NetworkAliasDNS.zone("my.net", dnsDomain: "test") == "my.net.test")
        #expect(NetworkAliasDNS.zone("MyNet", dnsDomain: "test") == "mynet.test")
    }

    // MARK: - qualifiedAliases

    @Test("the container name is dropped when it repeats the attachment hostname")
    func nameDropsDuplicateHostname() {
        #expect(
            NetworkAliasDNS.qualifiedAliases(
                [name], network: "myapp_default", dnsDomain: "test",
                hostname: hostname
            ).isEmpty
        )
    }

    @Test("the container name comes first when the hostname is a different one")
    func qualifiedDotlessAlias() {
        #expect(
            NetworkAliasDNS.qualifiedAliases(
                [name, "web"], network: "myapp_default", dnsDomain: "test", hostname: explicitHostname)
                == [hostname, "web.myapp_default.test"]
        )
    }

    @Test("aliases already ending in the domain are left alone")
    func qualifiedPassesFQDNs() {
        #expect(
            NetworkAliasDNS.qualifiedAliases(
                [name, "web.test"], network: "myapp_default", dnsDomain: "test", hostname: hostname)
                == ["web.test"]
        )
    }

    @Test("dotted aliases are zone-qualified, never registered raw")
    func qualifiedDottedAlias() {
        #expect(
            NetworkAliasDNS.qualifiedAliases(
                [name, "foo.bar"], network: "myapp_default", dnsDomain: "test", hostname: hostname)
                == ["foo.bar.myapp_default.test"]
        )
    }

    @Test("a subtree alias is zone-qualified")
    func qualifiedSubtreeAlias() {
        #expect(
            NetworkAliasDNS.qualifiedAliases(
                [name, ".example.internal"], network: "myapp_default", dnsDomain: "test", hostname: hostname)
                == [".example.internal.myapp_default.test"]
        )
    }

    @Test("an alias the guest resolver may not expand warns")
    func qualifiedWarnsForUnexpandedAlias() {
        var warnings: [String] = []
        let aliases = NetworkAliasDNS.qualifiedAliases(
            [name, "db.example.com"], network: "myapp_default", dnsDomain: "test", hostname: hostname,
            warn: { warnings.append($0) }
        )
        #expect(aliases == ["db.example.com.myapp_default.test"])
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("db.example.com") == true)
        #expect(warnings.first?.contains("db.example.com.myapp_default.test") == true)
    }

    @Test("an alias with fewer dots than ndots does not warn")
    func qualifiedDoesNotWarnForExpandedAlias() {
        var warnings: [String] = []
        _ = NetworkAliasDNS.qualifiedAliases(
            [name, "db.example"], network: "myapp_default", dnsDomain: "test", hostname: hostname,
            warn: { warnings.append($0) }
        )
        _ = NetworkAliasDNS.qualifiedAliases(
            [name, ".example"], network: "myapp_default", dnsDomain: "test", hostname: hostname,
            warn: { warnings.append($0) }
        )
        #expect(warnings.isEmpty)
    }

    @Test("a subtree alias counts its leading dot")
    func qualifiedWarnsForSubtreeAlias() {
        var warnings: [String] = []
        _ = NetworkAliasDNS.qualifiedAliases(
            [name, ".example.internal"], network: "myapp_default", dnsDomain: "test", hostname: hostname,
            warn: { warnings.append($0) }
        )
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains(".example.internal.myapp_default.test") == true)
    }

    @Test("empty aliases are dropped")
    func qualifiedDropsEmptyAliases() {
        #expect(
            NetworkAliasDNS.qualifiedAliases(
                [name, "", "web", ""], network: "myapp_default", dnsDomain: "test", hostname: hostname)
                == ["web.myapp_default.test"]
        )
    }

    @Test("deduplication is case-insensitive and keeps the first occurrence")
    func qualifiedDedupCaseInsensitive() {
        #expect(
            NetworkAliasDNS.qualifiedAliases(
                [name, "Web", "web", "WEB"], network: "myapp_default", dnsDomain: "test", hostname: hostname)
                == ["Web.myapp_default.test"]
        )
    }

    @Test("deduplication ignores a trailing dot")
    func qualifiedDedupIgnoresTrailingDot() {
        #expect(
            NetworkAliasDNS.qualifiedAliases(
                [name, "web.myapp_default.test.", "web.myapp_default.test"],
                network: "myapp_default", dnsDomain: "test", hostname: hostname)
                == ["web.myapp_default.test."]
        )
    }

    @Test("the hostname exclusion is case- and trailing-dot-insensitive")
    func qualifiedExcludesOwnHostnameCanonically() {
        #expect(
            NetworkAliasDNS.qualifiedAliases(
                [name, "Host.myapp_default.test", "HOST.myapp_default.test."], network: "myapp_default", dnsDomain: "test",
                hostname: explicitHostname
            ) == [hostname]
        )
    }

    @Test("aliases are qualified per network")
    func qualifiedPerNetwork() {
        let aliases = ["web"]
        #expect(
            NetworkAliasDNS.qualifiedAliases(
                [name] + aliases, network: "app_a", dnsDomain: "test", hostname: hostname)
                == ["c1.app_a.test", "web.app_a.test"]
        )
        #expect(
            NetworkAliasDNS.qualifiedAliases(
                [name] + aliases, network: "app_b", dnsDomain: "test", hostname: hostname)
                == ["c1.app_b.test", "web.app_b.test"]
        )
    }

    // MARK: - isFQDN / qualify

    @Test(
        "FQDNs end with a trailing dot or the dnsDomain",
        arguments: [
            ("web.myapp_default.test", true),
            ("web.test", true),
            ("web.other.", true),
            ("web", false),
            ("web.other-domain", false),
            ("foo.bar", false),
        ]
    )
    func fqdnDetection(name: String, expected: Bool) {
        #expect(NetworkAliasDNS.isFQDN(name, dnsDomain: "test") == expected)
    }

    @Test("qualify appends the network zone unless the name is already an FQDN")
    func qualifyNames() {
        #expect(
            NetworkAliasDNS.qualify("web", network: "myapp_default", dnsDomain: "test")
                == "web.myapp_default.test")
        #expect(
            NetworkAliasDNS.qualify("foo.bar", network: "myapp_default", dnsDomain: "test")
                == "foo.bar.myapp_default.test")
        #expect(
            NetworkAliasDNS.qualify("web.other.", network: "myapp_default", dnsDomain: "test")
                == "web.other.")
    }

    // MARK: - searchDomains

    @Test("search domains follow network order with the bare domain last")
    func searchDomainsMultiNetwork() {
        #expect(
            NetworkAliasDNS.searchDomains(networks: ["myapp_default", "app_2"], dnsDomain: "test")
                == ["myapp_default.test", "app_2.test", "test"]
        )
    }

    @Test("duplicate search domains are dropped, keeping the first occurrence")
    func searchDomainsDeduplicated() {
        #expect(
            NetworkAliasDNS.searchDomains(networks: ["my_app", "my_app"], dnsDomain: "test")
                == ["my_app.test", "test"]
        )
    }

    @Test("a single network yields its zone plus the bare domain")
    func searchDomainsSingleNetwork() {
        #expect(
            NetworkAliasDNS.searchDomains(networks: ["myapp_default"], dnsDomain: "test")
                == ["myapp_default.test", "test"]
        )
    }

    // MARK: - ndots

    @Test("ndots defaults to 2 when the user gives none")
    func ndotsDefault() {
        #expect(NetworkAliasDNS.ndots(from: []) == "ndots:2")
        #expect(NetworkAliasDNS.ndots(from: ["timeout:1", "rotate"]) == "ndots:2")
    }

    @Test("ndots is raised to at least 2")
    func ndotsMinimum() {
        #expect(NetworkAliasDNS.ndots(from: ["ndots:1"]) == "ndots:2")
        #expect(NetworkAliasDNS.ndots(from: ["ndots:0"]) == "ndots:2")
    }

    @Test("ndots above 2 is preserved")
    func ndotsPreserved() {
        #expect(NetworkAliasDNS.ndots(from: ["ndots:5"]) == "ndots:5")
        #expect(NetworkAliasDNS.ndots(from: ["timeout:1", "ndots:3"]) == "ndots:3")
    }
}
