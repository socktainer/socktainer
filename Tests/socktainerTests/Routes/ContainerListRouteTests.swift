import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

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

private func makeRunningSnapshot(id: String, networks: [ContainerResource.Attachment]) -> ContainerSnapshot {
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
    let config = ContainerConfiguration(id: id, image: imageDesc, process: processConfig)
    return ContainerSnapshot(
        configuration: config,
        status: .running,
        networks: networks,
        startedDate: Date(timeIntervalSinceNow: -30)
    )
}

@Suite("ContainerListRoute network settings")
struct ContainerListRouteNetworkSettingsTests {

    private func withRoute(
        container: ContainerSnapshot,
        test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)

            let client = MockContainerClient(containers: [container])
            try app.register(collection: ContainerListRoute(client: client))
            try await test(app)
        }
    }

    @Test("A running container with an IPv6 attachment lists GlobalIPv6Address and prefix length")
    func listReportsIPv6Attachment() async throws {
        let attachment = try ContainerResource.Attachment(
            network: "mynet",
            hostname: "c1",
            ipv4Address: CIDRv4("192.168.64.5/24"),
            ipv4Gateway: IPv4Address("192.168.64.1"),
            ipv6Address: CIDRv6("fd18:2f24:9eff:1:1c1e:56ff:fe7c:1a2b/64"),
            macAddress: nil
        )
        let container = makeRunningSnapshot(id: "c1", networks: [attachment])
        try await withRoute(container: container) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json") { res async throws in
                let summaries = try res.content.decode([RESTContainerSummary].self)
                let endpoint = summaries.first?.NetworkSettings.Networks?["mynet"]
                #expect(endpoint?.IPAddress == "192.168.64.5")
                #expect(endpoint?.IPPrefixLen == 24)
                #expect(endpoint?.GlobalIPv6Address == "fd18:2f24:9eff:1:1c1e:56ff:fe7c:1a2b")
                #expect(endpoint?.GlobalIPv6PrefixLen == 64)
                #expect(endpoint?.IPv6Gateway == nil)
            }
        }
    }

    @Test("A running container without an IPv6 attachment lists no IPv6 fields")
    func listReportsNoIPv6ForIPv4OnlyAttachment() async throws {
        let attachment = try ContainerResource.Attachment(
            network: "mynet",
            hostname: "c1",
            ipv4Address: CIDRv4("192.168.64.5/24"),
            ipv4Gateway: IPv4Address("192.168.64.1"),
            ipv6Address: nil,
            macAddress: nil
        )
        let container = makeRunningSnapshot(id: "c1", networks: [attachment])
        try await withRoute(container: container) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json") { res async throws in
                let summaries = try res.content.decode([RESTContainerSummary].self)
                let endpoint = summaries.first?.NetworkSettings.Networks?["mynet"]
                #expect(endpoint?.GlobalIPv6Address == nil)
                #expect(endpoint?.GlobalIPv6PrefixLen == nil)
            }
        }
    }

    @Test("Duplicate live network names do not crash list")
    func duplicateLiveNetworkNamesDoNotCrash() async throws {
        let attachment = try ContainerResource.Attachment(
            network: "dup",
            hostname: "c1",
            ipv4Address: CIDRv4("192.168.64.5/24"),
            ipv4Gateway: IPv4Address("192.168.64.1"),
            ipv6Address: nil,
            macAddress: nil
        )
        let container = makeRunningSnapshot(id: "c1", networks: [attachment, attachment])
        try await withRoute(container: container) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json") { res async throws in
                let summaries = try res.content.decode([RESTContainerSummary].self)
                #expect(summaries.first?.NetworkSettings.Networks?.keys.contains("dup") == true)
            }
        }
    }
}
