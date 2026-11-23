import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

/// `GET /networks/{id}` keyed `Containers` by the container's name, while `docker ps` and
/// `docker inspect` report the 64-hex Docker ID. .NET Aspire's DCP looks a container up
/// in the network by that ID and waited forever.
@Suite("Network Containers keys")
struct NetworkContainersKeyTests {
    private func network(_ name: String) throws -> RESTNetworkSummary {
        let configuration = try NetworkConfiguration(
            name: name, mode: .nat, ipv4Subnet: nil, labels: ResourceLabels([:]), plugin: "container-network-vmnet")
        let status = NetworkStatus(
            ipv4Subnet: try CIDRv4("192.168.100.0/24"), ipv4Gateway: try IPv4Address("192.168.100.1"), ipv6Subnet: nil)
        return RESTNetworkSummary(networkResource: NetworkResource(configuration: configuration, status: status))
    }

    private func container(
        _ id: String, network: String, ip: String, labels: [String: String] = [:]
    ) throws -> ContainerSnapshot {
        let process = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
        let image = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
        var configuration = ContainerConfiguration(id: id, image: image, process: process)
        configuration.labels = labels
        let attachment = try ContainerResource.Attachment(
            network: network, hostname: id, ipv4Address: CIDRv4(ip), ipv4Gateway: IPv4Address("192.168.100.1"),
            ipv6Address: nil, macAddress: nil)
        return ContainerSnapshot(
            configuration: configuration, status: .running, networks: [attachment], startedDate: Date(timeIntervalSinceNow: -30))
    }

    @Test("keys are the Docker container IDs and Name is the container name")
    func keyedByDockerID() throws {
        let net = try network("appnet")
        let attached = try container("demo", network: "appnet", ip: "192.168.100.5/24")
        let elsewhere = try container("other", network: "othernet", ip: "192.168.101.5/24")

        let containers = ClientNetworkService.containers(attachedTo: net, in: [attached, elsewhere])

        let hexId = DockerContainerID.hexId(for: attached)
        #expect(Array(containers.keys) == [hexId])
        #expect(containers[hexId]?.Name == "demo")
        #expect(containers[hexId]?.IPv4Address == "192.168.100.5/24")
    }

    @Test("a renamed container keeps the Docker ID that docker ps reports")
    func renamedContainerKeepsItsID() throws {
        let net = try network("appnet")
        let renamed = try container(
            "web-renamed", network: "appnet", ip: "192.168.100.6/24",
            labels: [DockerContainerID.idSeedLabel: "web"])

        let containers = ClientNetworkService.containers(attachedTo: net, in: [renamed])

        let hexId = DockerContainerID.hexId(for: renamed)
        #expect(Array(containers.keys) == [hexId])
        #expect(hexId != DockerContainerID.hexId(nativeId: "web-renamed", createdAt: nil))
        #expect(containers[hexId]?.Name == "web-renamed")
    }

    @Test("DNS sidecars are left out")
    func dnsSidecarExcluded() throws {
        let net = try network("appnet")
        let sidecar = try container(
            "dns-appnet", network: "appnet", ip: "192.168.100.2/24",
            labels: [NetworkDNSManager.roleLabel: NetworkDNSManager.dnsRole])

        #expect(ClientNetworkService.containers(attachedTo: net, in: [sidecar]).isEmpty)
    }
}
