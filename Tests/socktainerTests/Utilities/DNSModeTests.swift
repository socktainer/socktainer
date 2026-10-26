import Testing

@testable import socktainer

@Suite("DNSMode")
struct DNSModeTests {

    private func resolveError(flag: String?, environment: [String: String]) -> DNSModeError? {
        do {
            _ = try DNSMode.resolve(flag: flag, environment: environment)
            return nil
        } catch {
            return error as? DNSModeError
        }
    }

    @Test("flag values map to their cases")
    func flagValues() throws {
        #expect(try DNSMode.resolve(flag: "socktainer-dns", environment: [:]) == .socktainerDNS)
        #expect(try DNSMode.resolve(flag: "apple-dns", environment: [:]) == .appleDNS)
    }

    @Test("flag parsing is case-insensitive")
    func flagCaseInsensitive() throws {
        #expect(try DNSMode.resolve(flag: "APPLE-Dns", environment: [:]) == .appleDNS)
        #expect(try DNSMode.resolve(flag: "SocKtainer-DNS", environment: [:]) == .socktainerDNS)
    }

    @Test("the flag wins over the environment")
    func flagBeatsEnvironment() throws {
        #expect(
            try DNSMode.resolve(
                flag: "socktainer-dns",
                environment: ["SOCKTAINER_DNS_MODE": "apple-dns"]
            ) == .socktainerDNS
        )
        #expect(
            try DNSMode.resolve(
                flag: "apple-dns",
                environment: ["SOCKTAINER_DNS_MODE": "socktainer-dns"]
            ) == .appleDNS
        )
    }

    @Test("the environment is used when no flag is given")
    func environmentAlone() throws {
        #expect(try DNSMode.resolve(flag: nil, environment: ["SOCKTAINER_DNS_MODE": "apple-dns"]) == .appleDNS)
        #expect(try DNSMode.resolve(flag: nil, environment: ["SOCKTAINER_DNS_MODE": "SOCKTAINER-DNS"]) == .socktainerDNS)
    }

    @Test("the default is socktainer-dns")
    func defaultIsSocktainerDNS() throws {
        #expect(try DNSMode.resolve(flag: nil, environment: [:]) == .socktainerDNS)
    }

    @Test("an empty environment value falls back to socktainer-dns")
    func emptyEnvironmentValue() throws {
        #expect(try DNSMode.resolve(flag: nil, environment: ["SOCKTAINER_DNS_MODE": ""]) == .socktainerDNS)
    }

    @Test("an invalid flag value throws with the expected values in the description")
    func invalidFlagThrows() throws {
        let error = resolveError(flag: "aliases", environment: [:])
        #expect(error != nil)
        let description = error?.description ?? ""
        #expect(description.contains("aliases"))
        #expect(description.contains("--dns-mode"))
        #expect(description.contains("'socktainer-dns' or 'apple-dns'"))
    }

    @Test("an invalid environment value throws with the expected values in the description")
    func invalidEnvironmentThrows() throws {
        let error = resolveError(flag: nil, environment: ["SOCKTAINER_DNS_MODE": "host"])
        #expect(error != nil)
        let description = error?.description ?? ""
        #expect(description.contains("host"))
        #expect(description.contains("SOCKTAINER_DNS_MODE"))
        #expect(description.contains("'socktainer-dns' or 'apple-dns'"))
    }
}

@Suite("DNSMode.validateStartup")
struct DNSModeValidateStartupTests {

    private func startupError(
        _ mode: DNSMode,
        domain: String?,
        registeredDomains: [String] = ["test"]
    ) -> DNSModeError? {
        do {
            try mode.validateStartup(domain: domain, registeredDomains: registeredDomains)
            return nil
        } catch {
            return error as? DNSModeError
        }
    }

    @Test("socktainer-dns mode has no startup requirements")
    func socktainerDNSNeverThrows() {
        #expect(startupError(.socktainerDNS, domain: nil, registeredDomains: []) == nil)
        #expect(startupError(.socktainerDNS, domain: "test", registeredDomains: []) == nil)
    }

    @Test("apple-dns mode requires a DNS domain")
    func appleDNSRequiresDomain() throws {
        // nil and empty (`domain = ""` in config.toml) are both missing domains.
        for domain in [nil, ""] as [String?] {
            guard case .missingDomain? = startupError(.appleDNS, domain: domain) else {
                Issue.record("expected .missingDomain for domain \(String(describing: domain))")
                return
            }
        }
        let description = startupError(.appleDNS, domain: nil)?.description ?? ""
        #expect(description.contains("--dns-mode apple-dns"))
        #expect(description.contains("requires a DNS domain"))
    }

    @Test("apple-dns mode requires the domain to be registered in /etc/resolver")
    func appleDNSRequiresRegisteredDomain() throws {
        let error = startupError(.appleDNS, domain: "test", registeredDomains: ["other"])
        guard case .unregisteredResolverDomain(let domain)? = error else {
            Issue.record("expected .unregisteredResolverDomain, got \(String(describing: error))")
            return
        }
        #expect(domain == "test")
        #expect((error?.description ?? "").contains("to be registered with apple/container"))
    }

    @Test("apple-dns mode passes once the domain is registered")
    func appleDNSPassesWithRegisteredDomain() {
        #expect(startupError(.appleDNS, domain: "test", registeredDomains: ["test"]) == nil)
    }

    @Test("the registered domain is matched case-insensitively")
    func appleDNSPassesWithDifferentCase() {
        #expect(startupError(.appleDNS, domain: "Test", registeredDomains: ["test"]) == nil)
    }

}
