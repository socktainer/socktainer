import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression tests for issue #279: a stopped container that was correctly
/// attached to a named network reported `NetworkSettings.Networks: {}` on
/// inspect. Apple Container only tracks live attachments (`container.networks`
/// is `[]` once stopped) — this asserts the route falls back to the persisted
/// `configuration.networks` so Docker clients still see the attachment.
private struct MockContainerClient: ClientContainerProtocol {
    let containers: [ContainerSnapshot]

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { containers }
    func getContainer(id: String) async throws -> ContainerSnapshot? { containers.first { $0.id == id } }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

private func makeSnapshot(
    id: String,
    status: RuntimeStatus,
    configuredNetworks: [AttachmentConfiguration],
    liveNetworks: [ContainerResource.Attachment]
) -> ContainerSnapshot {
    let processConfig = ProcessConfiguration(
        executable: "/bin/sh",
        arguments: [],
        environment: [],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0)
    )
    let imageDesc = ImageDescription(
        reference: "alpine:latest",
        descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
    )
    var config = ContainerConfiguration(id: id, image: imageDesc, process: processConfig)
    config.networks = configuredNetworks
    return ContainerSnapshot(
        configuration: config,
        status: status,
        networks: liveNetworks,
        startedDate: status == .running ? Date(timeIntervalSinceNow: -30) : nil
    )
}

@Suite("ContainerInspectRoute network settings")
struct ContainerInspectRouteNetworkSettingsTests {

    private func withRoute(
        container: ContainerSnapshot,
        test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)

            let client = MockContainerClient(containers: [container])
            try app.register(collection: ContainerInspectRoute(client: client))
            try await test(app)
        }
    }

    @Test("A stopped container still reports its configured network attachment")
    func stoppedContainerReportsConfiguredNetwork() async throws {
        let container = makeSnapshot(
            id: "c1",
            status: .stopped,
            configuredNetworks: [AttachmentConfiguration(network: "mynet", options: AttachmentOptions(hostname: "c1"))],
            liveNetworks: []
        )
        try await withRoute(container: container) { app in
            try await app.testing().test(.GET, "/v1.51/containers/c1/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.NetworkSettings.Networks?.keys.contains("mynet") == true)
                #expect(inspect.Config.NetworkDisabled == false)
            }
        }
    }

    @Test("A running container reports its live network attachment with IP info")
    func runningContainerReportsLiveNetwork() async throws {
        let attachment = try ContainerResource.Attachment(
            network: "mynet",
            hostname: "c1",
            ipv4Address: CIDRv4("192.168.64.5/24"),
            ipv4Gateway: IPv4Address("192.168.64.1"),
            ipv6Address: nil,
            macAddress: nil
        )
        let container = makeSnapshot(
            id: "c1",
            status: .running,
            configuredNetworks: [AttachmentConfiguration(network: "mynet", options: AttachmentOptions(hostname: "c1"))],
            liveNetworks: [attachment]
        )
        try await withRoute(container: container) { app in
            try await app.testing().test(.GET, "/v1.51/containers/c1/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.NetworkSettings.Networks?["mynet"]?.IPAddress == "192.168.64.5")
            }
        }
    }

    @Test("Duplicate configured network names do not crash inspect")
    func duplicateConfiguredNetworkNamesDoNotCrash() async throws {
        let container = makeSnapshot(
            id: "c1",
            status: .stopped,
            configuredNetworks: [
                AttachmentConfiguration(network: "dup", options: AttachmentOptions(hostname: "c1")),
                AttachmentConfiguration(network: "dup", options: AttachmentOptions(hostname: "c1")),
            ],
            liveNetworks: []
        )
        try await withRoute(container: container) { app in
            try await app.testing().test(.GET, "/v1.51/containers/c1/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.NetworkSettings.Networks?.keys.contains("dup") == true)
            }
        }
    }

    @Test("Duplicate live network names do not crash inspect")
    func duplicateLiveNetworkNamesDoNotCrash() async throws {
        let attachment = try ContainerResource.Attachment(
            network: "dup",
            hostname: "c1",
            ipv4Address: CIDRv4("192.168.64.5/24"),
            ipv4Gateway: IPv4Address("192.168.64.1"),
            ipv6Address: nil,
            macAddress: nil
        )
        let container = makeSnapshot(
            id: "c1",
            status: .running,
            configuredNetworks: [AttachmentConfiguration(network: "dup", options: AttachmentOptions(hostname: "c1"))],
            liveNetworks: [attachment, attachment]
        )
        try await withRoute(container: container) { app in
            try await app.testing().test(.GET, "/v1.51/containers/c1/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.NetworkSettings.Networks?.keys.contains("dup") == true)
            }
        }
    }

    @Test("No configured networks at all is reported as network-disabled")
    func noNetworksIsDisabled() async throws {
        let container = makeSnapshot(id: "c1", status: .stopped, configuredNetworks: [], liveNetworks: [])
        try await withRoute(container: container) { app in
            try await app.testing().test(.GET, "/v1.51/containers/c1/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.NetworkSettings.Networks?.isEmpty ?? true)
                #expect(inspect.Config.NetworkDisabled == true)
            }
        }
    }
}

/// Regression tests ensuring `docker inspect` reflects the restart-policy state that
/// `RestartPolicyManager` / `ContainerRestartState` track internally — previously
/// `HostConfig.RestartPolicy` was always nil and `RestartCount` was hardcoded to 0.
@Suite("ContainerInspectRoute — restart-policy fidelity")
struct ContainerInspectRouteRestartPolicyTests {

    // MARK: - Helpers

    private func makeSnapshot(nativeId: String, restartPolicyLabel: String? = nil) -> ContainerSnapshot {
        let proc = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
        let img = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: "sha256:abc",
                size: 0
            )
        )
        var containerConfig = ContainerConfiguration(id: nativeId, image: img, process: proc)
        if let restartPolicyLabel {
            containerConfig.labels = [RestartPolicyManager.label: restartPolicyLabel]
        }
        return ContainerSnapshot(configuration: containerConfig, status: .stopped, networks: [])
    }

    private func encodedPolicy(name: String, maximumRetryCount: Int? = nil) -> String {
        let policy = RestartPolicy(Name: name, MaximumRetryCount: maximumRetryCount)
        return String(data: try! JSONEncoder().encode(policy), encoding: .utf8)!
    }

    // MARK: - Tests

    @Test("HostConfig.RestartPolicy round-trips the persisted label")
    func restartPolicyRoundTrips() async throws {
        let nativeId = "inspect-restart-policy-ctr"
        let snapshot = makeSnapshot(nativeId: nativeId, restartPolicyLabel: encodedPolicy(name: "on-failure", maximumRetryCount: 5))
        let mock = InspectMock(snapshot: snapshot)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: ContainerInspectRoute(client: mock))

            try await app.testing().test(.GET, "/v1.51/containers/\(nativeId)/json") { res async throws in
                #expect(res.status == .ok)
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.HostConfig.RestartPolicy?.Name == "on-failure")
                #expect(inspect.HostConfig.RestartPolicy?.MaximumRetryCount == 5)
            }
        }
    }

    @Test("HostConfig.RestartPolicy defaults to 'no' when no policy was requested")
    func restartPolicyDefaultsToNo() async throws {
        let nativeId = "inspect-no-restart-policy-ctr"
        let snapshot = makeSnapshot(nativeId: nativeId)
        let mock = InspectMock(snapshot: snapshot)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: ContainerInspectRoute(client: mock))

            try await app.testing().test(.GET, "/v1.51/containers/\(nativeId)/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.HostConfig.RestartPolicy?.Name == "no")
            }
        }
    }

    @Test("RestartCount reflects ContainerRestartState's tracked attempt count")
    func restartCountReflectsAttempts() async throws {
        let nativeId = "inspect-restart-count-ctr"
        let snapshot = makeSnapshot(nativeId: nativeId, restartPolicyLabel: encodedPolicy(name: "always"))
        let mock = InspectMock(snapshot: snapshot)

        _ = await ContainerRestartState.shared.nextAttempt(id: nativeId)
        _ = await ContainerRestartState.shared.nextAttempt(id: nativeId)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: ContainerInspectRoute(client: mock))

            try await app.testing().test(.GET, "/v1.51/containers/\(nativeId)/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.RestartCount == 2)
            }
        }

        await ContainerRestartState.shared.reset(id: nativeId)
    }

    @Test("State.Restarting and Status reflect a pending automatic restart")
    func pendingRestartReflectedInState() async throws {
        let nativeId = "inspect-pending-restart-ctr"
        let snapshot = makeSnapshot(nativeId: nativeId, restartPolicyLabel: encodedPolicy(name: "always"))
        let mock = InspectMock(snapshot: snapshot)

        await ContainerRestartState.shared.markPendingRestart(id: nativeId)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: ContainerInspectRoute(client: mock))

            try await app.testing().test(.GET, "/v1.51/containers/\(nativeId)/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.State.Restarting == true)
                #expect(inspect.State.Status == "restarting")
                #expect(inspect.State.Dead == false, "a container pending an automatic restart must not also report Dead")
            }
        }

        await ContainerRestartState.shared.reset(id: nativeId)
    }

    @Test("State.Restarting is false and Status is unaffected when no restart is pending")
    func noPendingRestartLeavesStateUnaffected() async throws {
        let nativeId = "inspect-no-pending-restart-ctr"
        let snapshot = makeSnapshot(nativeId: nativeId)
        let mock = InspectMock(snapshot: snapshot)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: ContainerInspectRoute(client: mock))

            try await app.testing().test(.GET, "/v1.51/containers/\(nativeId)/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.State.Restarting == false)
                #expect(inspect.State.Status == "exited")
            }
        }
    }
}

// MARK: - Mock

/// Mock that returns `snapshot` for any `getContainer` call.
private struct InspectMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
