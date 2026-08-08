import ContainerResource
import ContainerizationOCI
import CryptoKit
import Foundation
import Testing

@testable import socktainer

@Suite("Embedded network relay")
struct EmbeddedRelayImageTests {
    @Test("embedded OCI bytes match the reviewed arm64 artifact")
    func artifactDigest() {
        let digest = SHA256.hash(data: SocktainerRelayImage.archiveData).hexString
        #expect(digest == "fecfe7bc19b94c55dad79952bf5c648bf2415741c63318ec932852020bbcd910")
    }

    @Test("loadable archive owns the canonical tag and advertises arm64")
    func preparedArchive() throws {
        let canonical = "docker.io/library/socktainer-port-relay:embedded"
        let prepared = try EmbeddedRelayImage.prepareLoadableArchive(canonicalTag: canonical)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let layout = prepared.directory.appendingPathComponent("verify")
        try ArchiveUtility.extract(
            tarPath: prepared.archive,
            to: layout,
            limits: .imageLoad,
            transactional: true
        )
        let index = try JSONDecoder().decode(
            Index.self,
            from: Data(contentsOf: layout.appendingPathComponent("index.json"))
        )
        #expect(index.manifests.count == 1)
        let descriptor = index.manifests[0]
        #expect(descriptor.platform == .current)
        #expect(descriptor.annotations?[AnnotationKeys.containerizationImageName] == canonical)
        #expect(descriptor.annotations?[AnnotationKeys.containerdImageName] == canonical)
        #expect(descriptor.annotations?[AnnotationKeys.openContainersImageName] == canonical)
    }

    @Test("relay socket path is deterministic, bounded, and private")
    func privateSocketDirectory() throws {
        let root = try RequestBodyFileWriter.createSecureTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let longNetwork = String(repeating: "network-", count: 20)
        let shortRoot = NetworkRelayManager.shortRuntimeRoot(seed: root)
        defer { try? FileManager.default.removeItem(at: shortRoot) }
        try NetworkRelayManager.ensurePrivateDirectory(shortRoot)
        let first = NetworkRelayManager.socketPath(for: longNetwork, under: shortRoot)
        let second = NetworkRelayManager.socketPath(for: longNetwork, under: shortRoot)
        #expect(first == second)
        #expect(first.utf8.count < 104)
        #expect(first.hasSuffix("/relay.sock"))
        let attributes = try FileManager.default.attributesOfItem(atPath: shortRoot.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: POSIXError(.EACCES)) {
            try NetworkRelayManager.ensurePrivateDirectory(link)
        }
    }

    @Test("relay sidecars are hidden as Socktainer infrastructure")
    func infrastructureVisibility() throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "socktainer-relay-test",
            networks: [(network: "test_default", ip: "192.168.65.3")],
            labels: [
                NetworkDNSManager.roleLabel: NetworkRelayManager.relayRole,
                NetworkDNSManager.networkLabel: "test_default",
            ]
        )
        #expect(NetworkRelayManager.isRelay(snapshot))
        #expect(ClientContainerService.isInfrastructureSidecar(snapshot))
        #expect(!ClientContainerService.isDNSSidecar(snapshot))
    }

    @Test("relay ownership isolates concurrent Socktainer instances")
    func instanceOwnership() throws {
        let firstRoot = URL(fileURLWithPath: "/tmp/socktainer-instance-a/metadata")
        let secondRoot = URL(fileURLWithPath: "/tmp/socktainer-instance-b/metadata")
        let firstOwner = NetworkRelayManager.ownerID(seed: firstRoot)
        let secondOwner = NetworkRelayManager.ownerID(seed: secondRoot)
        #expect(firstOwner == NetworkRelayManager.ownerID(seed: firstRoot))
        #expect(firstOwner != secondOwner)
        #expect(
            NetworkRelayManager.containerID(for: "shared-network", ownerID: firstOwner)
                != NetworkRelayManager.containerID(for: "shared-network", ownerID: secondOwner)
        )

        let snapshot = try makeContainerSnapshot(
            nativeId: NetworkRelayManager.containerID(
                for: "shared-network",
                ownerID: firstOwner
            ),
            networks: [(network: "shared-network", ip: "192.168.65.3")],
            labels: [
                NetworkDNSManager.roleLabel: NetworkRelayManager.relayRole,
                NetworkDNSManager.networkLabel: "shared-network",
                NetworkRelayManager.ownerLabel: firstOwner,
            ]
        )
        #expect(NetworkRelayManager.isOwnedRelay(snapshot, ownerID: firstOwner))
        #expect(!NetworkRelayManager.isOwnedRelay(snapshot, ownerID: secondOwner))
    }
}
