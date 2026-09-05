import Testing

@testable import socktainer

/// apple/container 1.3.0 removed `RequestScheme.auto`; `RegistryScheme` reproduces the removed
/// heuristic for the call sites that used to rely on it. See RegistryScheme.swift for the full
/// rationale, including the deliberate port-stripping deviation from the removed upstream code.
@Suite("RegistryScheme")
struct RegistrySchemeTests {

    @Test("localhost, with or without a port, resolves to http")
    func localhostIsInsecure() {
        #expect(RegistryScheme.scheme(forHost: "localhost", internalDnsDomain: nil) == .http)
        #expect(RegistryScheme.scheme(forHost: "localhost:5000", internalDnsDomain: nil) == .http)
    }

    @Test("hosts under the internal DNS domain resolve to http")
    func internalDnsDomainIsInsecure() {
        #expect(RegistryScheme.scheme(forHost: "registry.test", internalDnsDomain: "test") == .http)
        #expect(RegistryScheme.scheme(forHost: "registrytest", internalDnsDomain: "test") == .https)
    }

    @Test("RFC1918 private ranges resolve to http")
    func privateRangesAreInsecure() {
        #expect(RegistryScheme.scheme(forHost: "10.0.0.0", internalDnsDomain: nil) == .http)
        #expect(RegistryScheme.scheme(forHost: "10.255.255.255", internalDnsDomain: nil) == .http)
        #expect(RegistryScheme.scheme(forHost: "127.0.0.1", internalDnsDomain: nil) == .http)
        #expect(RegistryScheme.scheme(forHost: "192.168.1.1", internalDnsDomain: nil) == .http)
        #expect(RegistryScheme.scheme(forHost: "172.16.0.1", internalDnsDomain: nil) == .http)
        #expect(RegistryScheme.scheme(forHost: "172.31.255.255", internalDnsDomain: nil) == .http)
    }

    @Test("addresses just outside the private ranges resolve to https")
    func outsidePrivateRangesAreSecure() {
        #expect(RegistryScheme.scheme(forHost: "172.32.0.1", internalDnsDomain: nil) == .https)
        #expect(RegistryScheme.scheme(forHost: "11.0.0.1", internalDnsDomain: nil) == .https)
        #expect(RegistryScheme.scheme(forHost: "192.169.0.1", internalDnsDomain: nil) == .https)
    }

    @Test("public registries resolve to https")
    func publicRegistriesAreSecure() {
        #expect(RegistryScheme.scheme(forHost: "ghcr.io", internalDnsDomain: nil) == .https)
        #expect(RegistryScheme.scheme(forHost: "docker.io", internalDnsDomain: nil) == .https)
        #expect(RegistryScheme.scheme(forHost: "myregistry.example.com:8443", internalDnsDomain: nil) == .https)
    }

    @Test("scheme(forReference:) resolves via the reference's domain")
    func referenceResolution() {
        #expect(RegistryScheme.scheme(forReference: "nginx", internalDnsDomain: nil) == .https)
        #expect(RegistryScheme.scheme(forReference: "localhost:5000/img:tag", internalDnsDomain: nil) == .http)
        #expect(RegistryScheme.scheme(forReference: "ghcr.io/foo/bar", internalDnsDomain: nil) == .https)
    }
}
