import ContainerAPIClient
import ContainerResource
import Testing

@testable import socktainer

@Suite("DNS sidecar Docker API visibility")
struct DNSSidecarVisibilityTests {

    private func sidecar(network: String = "backend") throws -> ContainerSnapshot {
        try makeContainerSnapshot(
            nativeId: "socktainer-dns-\(network)",
            ip: "192.168.65.2",
            network: network,
            labels: [
                NetworkDNSManager.roleLabel: NetworkDNSManager.dnsRole,
                NetworkDNSManager.networkLabel: network,
            ],
            status: .running
        )
    }

    private func userContainer(name: String) throws -> ContainerSnapshot {
        try makeContainerSnapshot(nativeId: name, ip: "192.168.65.3", network: "backend", labels: ["app": "api"], status: .running)
    }

    @Test("withoutDNSSidecars drops DNS sidecars and keeps user containers")
    func withoutDNSSidecarsFiltersSidecars() throws {
        let snapshots = [try sidecar(), try userContainer(name: "api-server")]

        let visible = ClientContainerService.withoutDNSSidecars(snapshots)

        #expect(visible.map { $0.id } == ["api-server"])
    }

    @Test("startup adopts a running sidecar whose network exists, removes all others")
    func staleSidecarAdoption() {
        #expect(NetworkDNSManager.shouldAdoptSidecar(status: .running, networkExists: true))
        #expect(!NetworkDNSManager.shouldAdoptSidecar(status: .running, networkExists: false))
        #expect(!NetworkDNSManager.shouldAdoptSidecar(status: .stopped, networkExists: true))
    }

    @Test("isDNSSidecar matches only the socktainer.role=dns label")
    func sidecarDetection() throws {
        #expect(ClientContainerService.isDNSSidecar(try sidecar()))
        #expect(!ClientContainerService.isDNSSidecar(try userContainer(name: "api-server")))

        let otherRole = try makeContainerSnapshot(
            nativeId: "worker", ip: "192.168.65.4", network: "backend",
            labels: [NetworkDNSManager.roleLabel: "builder"], status: .running
        )
        #expect(!ClientContainerService.isDNSSidecar(otherRole))
    }
}
