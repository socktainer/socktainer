import ContainerResource
import ContainerizationExtras
import Darwin
import Logging
import Testing
import VaporTesting

@testable import socktainer

@Suite("Published port manager")
struct PublishedPortManagerTests {
    @Test("publication address skips reserved attachments")
    func publicationAddressSkipsReservedAttachments() throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "published-port-test",
            networks: [
                (network: "bridge", ip: "192.168.65.10"),
                (network: "compose_default", ip: "192.168.65.20"),
            ],
            labels: [:]
        )

        #expect(PublishedPortManager.publicationAddress(in: snapshot) == "192.168.65.20")
    }

    @Test("publication address falls back to Docker's default network")
    func publicationAddressUsesDefaultNetwork() throws {
        let snapshot = try makeContainerSnapshot(
            nativeId: "published-port-test",
            networks: [
                (network: "default", ip: "192.168.65.10"),
                (network: "none", ip: "192.168.65.11"),
            ],
            labels: [:]
        )

        #expect(PublishedPortManager.publicationAddress(in: snapshot) == "192.168.65.10")
    }

    @Test("desired specifications are canonical and expand ranges")
    func desiredSpecificationsAreCanonical() throws {
        let tcp = try PublishPort(
            hostAddress: IPAddress("127.0.0.1"),
            hostPort: 55001,
            containerPort: 5432,
            proto: .tcp,
            count: 2
        )
        let udp = try PublishPort(
            hostAddress: IPAddress("0.0.0.0"),
            hostPort: 55000,
            containerPort: 5353,
            proto: .udp,
            count: 1
        )

        let forward = PublishedPortManager.specifications(
            for: [tcp, udp],
            containerAddress: "192.168.65.20"
        )
        let reversed = PublishedPortManager.specifications(
            for: [udp, tcp],
            containerAddress: "192.168.65.20"
        )

        #expect(forward == reversed)
        #expect(forward.count == 3)
        #expect(forward.map(\.hostPort) == [55000, 55001, 55002])
        #expect(forward.map(\.containerPort) == [5353, 5432, 5433])
    }

    @Test("concurrent TCP and UDP dynamic reservations are transport-aware and unique")
    func concurrentDynamicReservations() async throws {
        try await withApp { app in
            let manager = PublishedPortManager(
                eventLoopGroup: app.eventLoopGroup,
                logger: Logger(label: "socktainer.tests.dynamic-ports")
            )
            let reservations = try await withThrowingTaskGroup(
                of: PublishedPortManager.DynamicPortReservation.self,
                returning: [PublishedPortManager.DynamicPortReservation].self
            ) { group in
                for index in 0..<32 {
                    group.addTask {
                        let proto: PublishProtocol = index.isMultiple(of: 2) ? .tcp : .udp
                        let mapping = try PublishPort(
                            hostAddress: IPAddress("127.0.0.1"),
                            hostPort: 0,
                            containerPort: UInt16(10_000 + index),
                            proto: proto,
                            count: 1
                        )
                        return try await manager.reserveDynamicPorts([mapping])
                    }
                }
                var values: [PublishedPortManager.DynamicPortReservation] = []
                for try await reservation in group { values.append(reservation) }
                return values
            }

            let tcp = reservations.flatMap(\.ports).filter { $0.proto == .tcp }
            let udp = reservations.flatMap(\.ports).filter { $0.proto == .udp }
            #expect(tcp.allSatisfy { $0.hostPort != 0 })
            #expect(udp.allSatisfy { $0.hostPort != 0 })
            #expect(Set(tcp.map(\.hostPort)).count == tcp.count)
            #expect(Set(udp.map(\.hostPort)).count == udp.count)

            let range = try PublishPort(
                hostAddress: IPAddress("127.0.0.1"),
                hostPort: 0,
                containerPort: 20_000,
                proto: .tcp,
                count: 3
            )
            let rangeReservation = try await manager.reserveDynamicPorts([range])
            let rangeBase = rangeReservation.ports[0].hostPort
            #expect(rangeBase != 0)
            #expect(rangeReservation.ports[0].count == 3)
            for offset in 0..<3 {
                #expect(!Self.canBindTCP(port: rangeBase + UInt16(offset)))
            }

            for reservation in reservations { await manager.cancel(reservation) }
            await manager.cancel(rangeReservation)
            for offset in 0..<3 {
                #expect(Self.canBindTCP(port: rangeBase + UInt16(offset)))
            }
            await manager.shutdown()
        }
    }

    @Test("concurrent reconciliation publishes one listener and close releases it")
    func concurrentReconciliationIsSerialized() async throws {
        try await withApp { app in
            let nativeID = "published-port-concurrent-reconcile"
            let manager = PublishedPortManager(
                eventLoopGroup: app.eventLoopGroup,
                logger: Logger(label: "socktainer.tests.concurrent-reconcile")
            )
            let requested = try PublishPort(
                hostAddress: IPAddress("127.0.0.1"),
                hostPort: 0,
                containerPort: 54_321,
                proto: .tcp,
                count: 1
            )
            let reservation = try await manager.reserveDynamicPorts([requested])
            let hostPort = try #require(reservation.ports.first?.hostPort)
            await manager.commit(reservation, nativeID: nativeID)
            try await DockerContainerMetadataStore.shared.set(
                nativeID: nativeID,
                name: nativeID,
                publishedPorts: reservation.ports
            )
            let snapshot = try makeContainerSnapshot(
                nativeId: nativeID,
                ip: "127.0.0.1",
                network: "compose_default",
                labels: [:],
                status: .running
            )
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<32 {
                        group.addTask { try await manager.reconcile(container: snapshot) }
                    }
                    try await group.waitForAll()
                }
            } catch {
                await manager.shutdown()
                try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
                throw error
            }

            #expect(await manager.cachedOperationLockCount() == 0)
            #expect(!Self.canBindTCP(port: hostPort))
            await manager.close(nativeID: nativeID)
            #expect(await manager.cachedOperationLockCount() == 0)
            #expect(Self.canBindTCP(port: hostPort))
            try await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
            await manager.shutdown()
        }
    }

    @Test("relay reconciliation selects the container network and remains single-owner")
    func relayReconciliationUsesNetworkProvider() async throws {
        try await withApp { app in
            let nativeID = "published-port-relay-provider"
            let provider = RecordingRelayProvider(socketPath: "/tmp/socktainer-relay-test-missing.sock")
            let manager = PublishedPortManager(
                eventLoopGroup: app.eventLoopGroup,
                logger: Logger(label: "socktainer.tests.relay-provider"),
                relayProvider: provider
            )
            let requested = try PublishPort(
                hostAddress: IPAddress("127.0.0.1"),
                hostPort: 0,
                containerPort: 5432,
                proto: .tcp,
                count: 1
            )
            let reservation = try await manager.reserveDynamicPorts([requested])
            let hostPort = try #require(reservation.ports.first?.hostPort)
            await manager.commit(reservation, nativeID: nativeID)
            try await DockerContainerMetadataStore.shared.set(
                nativeID: nativeID,
                name: nativeID,
                publishedPorts: reservation.ports
            )
            let snapshot = try makeContainerSnapshot(
                nativeId: nativeID,
                networks: [
                    (network: "bridge", ip: "192.168.64.8"),
                    (network: "project_default", ip: "192.168.99.4"),
                ],
                labels: [:],
                status: .running
            )
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<16 {
                        group.addTask { try await manager.reconcile(container: snapshot) }
                    }
                    try await group.waitForAll()
                }
            } catch {
                await manager.shutdown()
                try? await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
                throw error
            }
            let requestedNetworks = await provider.requestedNetworks()
            #expect(requestedNetworks.count == 16)
            #expect(requestedNetworks.allSatisfy { $0 == "project_default" })
            #expect(!Self.canBindTCP(port: hostPort))
            await manager.close(nativeID: nativeID)
            #expect(Self.canBindTCP(port: hostPort))
            try await DockerContainerMetadataStore.shared.remove(nativeID: nativeID)
            await manager.shutdown()
        }
    }

    private static func canBindTCP(port: UInt16) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            return false
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                ) == 0
            }
        }
    }
}

private actor RecordingRelayProvider: NetworkPortRelayProviding {
    private let socketPath: String
    private var networks: [String] = []

    init(socketPath: String) { self.socketPath = socketPath }

    func ensureRelay(networkID: String) async throws -> String {
        networks.append(networkID)
        return socketPath
    }

    func requestedNetworks() -> [String] { networks }
}
