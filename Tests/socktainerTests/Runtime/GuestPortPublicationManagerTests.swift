import Testing

@testable import socktainer

@Suite("Guest port publication")
struct GuestPortPublicationManagerTests {
    @Test("publishes direct TCP mappings and removes them by container")
    func publishAndRemove() async throws {
        let forwarder = PortForwarderSpy()
        let manager = GuestPortPublicationManager(forwarder: forwarder)

        let published = try await manager.publish(
            containerID: "nginx",
            bindings: [
                .init(
                    containerPort: 80,
                    proto: "tcp",
                    hostIP: "127.0.0.1",
                    hostPort: 18_080
                )
            ],
            guestAddress: "192.168.64.2",
            guestPorts: [20_000]
        )
        #expect(published.first?.hostPort == 18_080)

        let repeated = try await manager.publish(
            containerID: "nginx",
            bindings: [
                .init(
                    containerPort: 80,
                    proto: "tcp",
                    hostIP: "127.0.0.1",
                    hostPort: 18_080
                )
            ],
            guestAddress: "192.168.64.2",
            guestPorts: [20_000]
        )
        #expect(repeated == published)
        #expect(await forwarder.added.count == 1)

        #expect(
            await forwarder.added == [
                .init(
                    id: "nginx:tcp:80:127.0.0.1:18080",
                    hostAddress: "127.0.0.1",
                    hostPort: 18_080,
                    guestAddress: "192.168.64.2",
                    guestPort: 20_000
                )
            ]
        )
        await manager.remove(containerID: "nginx")
        #expect(await forwarder.removed == ["nginx:tcp:80:127.0.0.1:18080"])
        #expect(await manager.mappingIDs(containerID: "nginx").isEmpty)
    }

    @Test("supports UDP and requests an ephemeral port when host port is omitted")
    func validation() async throws {
        let udp = try GuestPortPublicationManager.mappings(
            containerID: "dns",
            bindings: [
                .init(containerPort: 53, proto: "udp", hostIP: "127.0.0.1", hostPort: 10_053)
            ],
            guestAddress: "192.168.64.2",
            guestPorts: [20_000]
        )
        #expect(udp.first?.id == "dns:udp:53:127.0.0.1:10053")
        let dynamic = try GuestPortPublicationManager.mappings(
            containerID: "web",
            bindings: [
                .init(
                    containerPort: 80,
                    proto: "tcp",
                    hostIP: "0.0.0.0",
                    hostPort: nil
                )
            ],
            guestAddress: "192.168.64.2",
            guestPorts: [20_000]
        )
        #expect(dynamic.first?.hostPort == 0)

        let twoDynamic = try GuestPortPublicationManager.mappings(
            containerID: "web",
            bindings: [
                .init(containerPort: 80, proto: "tcp", hostIP: "127.0.0.1", hostPort: nil),
                .init(containerPort: 443, proto: "tcp", hostIP: "127.0.0.1", hostPort: nil),
            ],
            guestAddress: "192.168.64.2",
            guestPorts: [20_000, 20_001]
        )
        #expect(Set(twoDynamic.map(\.id)).count == 2)

        let manager = GuestPortPublicationManager(forwarder: PortForwarderSpy())
        let published = try await manager.publish(
            containerID: "web",
            bindings: [
                .init(
                    containerPort: 80,
                    proto: "tcp",
                    hostIP: "127.0.0.1",
                    hostPort: nil
                )
            ],
            guestAddress: "192.168.64.2",
            guestPorts: [20_000]
        )
        #expect(published.first?.hostPort == 31_000)
    }

    @Test("publishes and removes UDP mappings")
    func udpPublishAndRemove() async throws {
        let udp = UDPPortForwarderSpy()
        let manager = GuestPortPublicationManager(
            forwarder: PortForwarderSpy(), udpForwarder: udp
        )
        let published = try await manager.publish(
            containerID: "dns",
            bindings: [.init(containerPort: 53, proto: "udp", hostIP: "127.0.0.1", hostPort: nil)],
            guestAddress: "192.168.64.2",
            guestPorts: [20_000]
        )
        #expect(published.first?.hostPort == 31_001)
        await manager.remove(containerID: "dns")
        #expect(await udp.removed == ["dns:udp:53:127.0.0.1:0"])
    }

    @Test("rolls back listeners when publication fails")
    func rollback() async {
        let forwarder = PortForwarderSpy(failAtAdd: 2)
        let manager = GuestPortPublicationManager(forwarder: forwarder)

        await #expect(throws: PortForwarderSpy.Failure.self) {
            try await manager.publish(
                containerID: "web",
                bindings: [
                    .init(containerPort: 80, proto: "tcp", hostIP: "127.0.0.1", hostPort: 18_080),
                    .init(containerPort: 81, proto: "tcp", hostIP: "127.0.0.1", hostPort: 18_081),
                ],
                guestAddress: "192.168.64.2",
                guestPorts: [20_000, 20_001]
            )
        }
        #expect(await forwarder.removed == ["web:tcp:80:127.0.0.1:18080"])
        #expect(await manager.mappingIDs(containerID: "web").isEmpty)
    }
}

private actor UDPPortForwarderSpy: DirectUDPPortForwarding {
    private(set) var removed: [String] = []

    func add(_ mapping: DirectUDPPortMapping) -> DirectUDPPortMapping {
        DirectUDPPortMapping(
            id: mapping.id,
            hostAddress: mapping.hostAddress,
            hostPort: mapping.hostPort == 0 ? 31_001 : mapping.hostPort,
            guestPort: mapping.guestPort
        )
    }

    func remove(id: String) { removed.append(id) }
}

private actor PortForwarderSpy: DirectTCPPortForwarding {
    struct Failure: Error {}

    private let failAtAdd: Int?
    private(set) var added: [DirectTCPPortMapping] = []
    private(set) var removed: [String] = []

    init(failAtAdd: Int? = nil) {
        self.failAtAdd = failAtAdd
    }

    func add(_ mapping: DirectTCPPortMapping) throws -> DirectTCPPortMapping {
        if added.count + 1 == failAtAdd { throw Failure() }
        added.append(mapping)
        guard mapping.hostPort == 0 else { return mapping }
        return DirectTCPPortMapping(
            id: mapping.id,
            hostAddress: mapping.hostAddress,
            hostPort: 31_000,
            guestAddress: mapping.guestAddress,
            guestPort: mapping.guestPort
        )
    }

    func remove(id: String) {
        removed.append(id)
    }
}
