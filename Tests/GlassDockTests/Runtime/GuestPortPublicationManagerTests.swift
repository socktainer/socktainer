import Testing

@testable import GlassDock

@Suite("Guest port publication")
struct GuestPortPublicationManagerTests {
    @Test("publishes TCP and UDP through one interface and removes by container")
    func publishAndRemove() async throws {
        let controller = InMemoryPublishedPortController()
        let manager = GuestPortPublicationManager(controller: controller)
        let bindings = [
            DockerRuntimePortBinding(
                containerPort: 80, proto: "tcp", hostIP: "127.0.0.1", hostPort: 18_080
            ),
            DockerRuntimePortBinding(
                containerPort: 53, proto: "udp", hostIP: "0.0.0.0", hostPort: 10_053
            ),
        ]

        let published = try await manager.publish(
            containerID: "server", bindings: bindings, guestPorts: [20_000, 20_001]
        )

        #expect(published == bindings)
        #expect(
            await controller.registry == [
                .init(local: "127.0.0.1:18080", remote: "192.168.127.2:20000", protocol: .tcp),
                .init(local: "0.0.0.0:10053", remote: "192.168.127.2:20001", protocol: .udp),
            ]
        )
        try await manager.remove(containerID: "server")
        #expect(await controller.registry.isEmpty)
    }

    @Test("repeated publication is idempotent and restores a lost gvproxy registry")
    func idempotencyAndRecovery() async throws {
        let controller = InMemoryPublishedPortController()
        let manager = GuestPortPublicationManager(controller: controller)
        let binding = DockerRuntimePortBinding(
            containerPort: 80, proto: "tcp", hostIP: "127.0.0.1", hostPort: 18_080
        )

        _ = try await manager.publish(
            containerID: "web", bindings: [binding], guestPorts: [20_000]
        )
        _ = try await manager.publish(
            containerID: "web", bindings: [binding], guestPorts: [20_000]
        )
        #expect(await controller.exposed.count == 1)

        await controller.reset()
        await controller.setGuestIPv4("192.168.127.3")
        try await manager.reconcile()
        #expect(await controller.exposed.count == 2)
        #expect(
            await controller.registry == [
                .init(
                    local: "127.0.0.1:18080",
                    remote: "192.168.127.3:20000",
                    protocol: .tcp
                )
            ]
        )
    }

    @Test("dynamic publication lets gvproxy atomically claim a free candidate")
    func dynamicPort() async throws {
        let controller = InMemoryPublishedPortController(addressInUseFailures: 2)
        let manager = GuestPortPublicationManager(controller: controller)

        let published = try await manager.publish(
            containerID: "web",
            bindings: [
                .init(containerPort: 80, proto: "tcp", hostIP: "127.0.0.1", hostPort: nil)
            ],
            guestPorts: [20_000]
        )

        #expect((49_152...65_535).contains(published[0].hostPort!))
        #expect(await controller.failedExposeCount == 2)
        #expect(await controller.registry.count == 1)
    }

    @Test("a partial batch failure rolls back only endpoints added by that transaction")
    func rollback() async throws {
        let existing = PublishedPortEndpoint(
            local: "127.0.0.1:18080", remote: "192.168.127.2:20000", protocol: .tcp
        )
        let controller = InMemoryPublishedPortController(
            initial: [existing], failAtExpose: 1
        )
        let manager = GuestPortPublicationManager(controller: controller)

        await #expect(throws: InMemoryPublishedPortController.Failure.self) {
            try await manager.publish(
                containerID: "web",
                bindings: [
                    .init(containerPort: 80, proto: "tcp", hostIP: "127.0.0.1", hostPort: 18_080),
                    .init(containerPort: 81, proto: "tcp", hostIP: "127.0.0.1", hostPort: 18_081),
                ],
                guestPorts: [20_000, 20_001]
            )
        }
        #expect(await controller.registry == [existing])
    }

    @Test("shutdown removes all endpoints owned by the module")
    func shutdown() async throws {
        let controller = InMemoryPublishedPortController()
        let manager = GuestPortPublicationManager(controller: controller)
        for id in ["one", "two"] {
            _ = try await manager.publish(
                containerID: id,
                bindings: [
                    .init(
                        containerPort: 80,
                        proto: "tcp",
                        hostIP: "127.0.0.1",
                        hostPort: id == "one" ? 18_080 : 18_081
                    )
                ],
                guestPorts: [20_000]
            )
        }

        await manager.shutdown()

        #expect(await controller.registry.isEmpty)
    }

    @Test("failed removal keeps ownership for a later reconciliation")
    func failedRemovalRetainsState() async throws {
        let controller = InMemoryPublishedPortController(failUnexpose: true)
        let manager = GuestPortPublicationManager(controller: controller)
        _ = try await manager.publish(
            containerID: "web",
            bindings: [
                .init(containerPort: 80, proto: "tcp", hostIP: "127.0.0.1", hostPort: 18_080)
            ],
            guestPorts: [20_000]
        )

        await #expect(throws: InMemoryPublishedPortController.Failure.self) {
            try await manager.remove(containerID: "web")
        }
        #expect(await manager.mappingIDs(containerID: "web") == ["tcp:127.0.0.1:18080"])
        #expect(await controller.registry.count == 1)
    }
}

private actor InMemoryPublishedPortController: PublishedPortControlling {
    struct Failure: Error {}

    private(set) var registry: Set<PublishedPortEndpoint>
    private(set) var exposed: [PublishedPortEndpoint] = []
    private(set) var failedExposeCount = 0
    private var guestAddress = "192.168.127.2"
    private var addressInUseFailures: Int
    private let failAtExpose: Int?
    private let failUnexpose: Bool

    init(
        initial: Set<PublishedPortEndpoint> = [],
        addressInUseFailures: Int = 0,
        failAtExpose: Int? = nil,
        failUnexpose: Bool = false
    ) {
        registry = initial
        self.addressInUseFailures = addressInUseFailures
        self.failAtExpose = failAtExpose
        self.failUnexpose = failUnexpose
    }

    func guestIPv4() -> String { guestAddress }
    func all() -> Set<PublishedPortEndpoint> { registry }

    func expose(_ endpoint: PublishedPortEndpoint) throws {
        if addressInUseFailures > 0 {
            addressInUseFailures -= 1
            failedExposeCount += 1
            throw GuestPortPublicationError.gvproxy(
                status: 500, message: "bind: address already in use"
            )
        }
        if exposed.count + 1 == failAtExpose { throw Failure() }
        guard
            !registry.contains(where: {
                $0.protocol == endpoint.protocol && $0.local == endpoint.local
            })
        else {
            throw GuestPortPublicationError.gvproxy(
                status: 500, message: "proxy already running"
            )
        }
        registry.insert(endpoint)
        exposed.append(endpoint)
    }

    func unexpose(_ endpoint: PublishedPortEndpoint) throws {
        if failUnexpose { throw Failure() }
        registry.remove(endpoint)
    }

    func reset() { registry.removeAll() }
    func setGuestIPv4(_ address: String) { guestAddress = address }
}
