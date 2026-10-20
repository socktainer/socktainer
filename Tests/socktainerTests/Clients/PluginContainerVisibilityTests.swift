import ContainerAPIClient
import ContainerResource
import Testing

@testable import socktainer

@Suite("Plugin container Docker API visibility")
struct PluginContainerVisibilityTests {

    private func k8sNode(_ name: String, role: String, status: RuntimeStatus = .running) throws -> ContainerSnapshot {
        try makeContainerSnapshot(
            nativeId: name,
            ip: "192.168.64.10",
            network: "default",
            labels: [
                ResourceLabelKeys.plugin: "k8s",
                ResourceLabelKeys.role: role,
            ],
            status: status
        )
    }

    private func machine(_ name: String) throws -> ContainerSnapshot {
        try makeContainerSnapshot(
            nativeId: name, ip: "192.168.64.11", network: "default",
            labels: [ResourceLabelKeys.plugin: "machine"], status: .running
        )
    }

    private func userContainer(_ name: String, status: RuntimeStatus = .running) throws -> ContainerSnapshot {
        try makeContainerSnapshot(nativeId: name, ip: "192.168.64.12", network: "default", labels: ["app": "api"], status: status)
    }

    private func snapshots() throws -> [ContainerSnapshot] {
        [
            try k8sNode("k8s-dev", role: "control-plane,worker"),
            try k8sNode("k8s-dev-worker-1", role: "worker", status: .stopped),
            try machine("devbox"),
            try userContainer("api-server"),
            try userContainer("old-job", status: .stopped),
        ]
    }

    @Test("isPluginContainer matches any value of the plugin label")
    func pluginContainerDetection() throws {
        #expect(ClientContainerService.isPluginContainer(try k8sNode("k8s-dev", role: "control-plane")))
        #expect(ClientContainerService.isPluginContainer(try machine("devbox")))
        #expect(!ClientContainerService.isPluginContainer(try userContainer("api-server")))

        // The builder carries only the role label, so it stays visible.
        let builder = try makeContainerSnapshot(
            nativeId: "buildkit", ip: "192.168.64.13", network: "default",
            labels: [ResourceLabelKeys.role: ResourceRoleValues.builder], status: .running
        )
        #expect(!ClientContainerService.isPluginContainer(builder))
    }

    @Test("listing hides plugin containers with no filter")
    func listingHidesPluginContainers() throws {
        let all = ClientContainerService.listing(try snapshots(), showAll: true, filters: [:])
        #expect(all.map(\.id) == ["api-server", "old-job"])

        let running = ClientContainerService.listing(try snapshots(), showAll: false, filters: [:])
        #expect(running.map(\.id) == ["api-server"])
    }

    @Test("listing hides plugin containers from filters that don't name the plugin label")
    func listingHidesPluginContainersFromOtherFilters() throws {
        let byName = ClientContainerService.listing(try snapshots(), showAll: true, filters: ["name": ["k8s-dev"]])
        #expect(byName.isEmpty)

        let byRole = ClientContainerService.listing(
            try snapshots(), showAll: true, filters: ["label": ["\(ResourceLabelKeys.role)=worker"]])
        #expect(byRole.isEmpty)
    }

    @Test("a label filter on the plugin label lists plugin containers")
    func pluginLabelFilterRevealsPluginContainers() throws {
        let anyPlugin = ClientContainerService.listing(
            try snapshots(), showAll: true, filters: ["label": [ResourceLabelKeys.plugin]])
        #expect(anyPlugin.map(\.id) == ["k8s-dev", "k8s-dev-worker-1", "devbox"])

        let k8s = ClientContainerService.listing(
            try snapshots(), showAll: false, filters: ["label": ["\(ResourceLabelKeys.plugin)=k8s"]])
        #expect(k8s.map(\.id) == ["k8s-dev"])
    }

    @Test("namesPluginLabel recognizes key, key=value and key!=value filters")
    func pluginLabelFilterForms() {
        #expect(ClientContainerService.namesPluginLabel([ResourceLabelKeys.plugin]))
        #expect(ClientContainerService.namesPluginLabel(["\(ResourceLabelKeys.plugin)=k8s"]))
        #expect(ClientContainerService.namesPluginLabel(["\(ResourceLabelKeys.plugin)!=machine"]))
        #expect(ClientContainerService.namesPluginLabel(["app=api", ResourceLabelKeys.plugin]))

        #expect(!ClientContainerService.namesPluginLabel([]))
        #expect(!ClientContainerService.namesPluginLabel(["app=api"]))
        #expect(!ClientContainerService.namesPluginLabel(["\(ResourceLabelKeys.plugin).extra=k8s"]))
        #expect(!ClientContainerService.namesPluginLabel(["app=\(ResourceLabelKeys.plugin)"]))
    }

    @Test("prune leaves out stopped plugin containers with no filter")
    func pruneLeavesOutPluginContainers() throws {
        let candidates = ClientContainerService.pruneCandidates(try snapshots(), filters: [:])
        #expect(candidates.map(\.id) == ["old-job"])

        let byRole = ClientContainerService.pruneCandidates(
            try snapshots(), filters: ["label": ["\(ResourceLabelKeys.role)=worker"]])
        #expect(byRole.isEmpty)
    }

    @Test("a label filter on the plugin label prunes stopped plugin containers")
    func pluginLabelFilterPrunesPluginContainers() throws {
        let k8s = ClientContainerService.pruneCandidates(
            try snapshots(), filters: ["label": ["\(ResourceLabelKeys.plugin)=k8s"]])
        #expect(k8s.map(\.id) == ["k8s-dev-worker-1"])

        let notMachine = ClientContainerService.pruneCandidates(
            try snapshots(), filters: ["label": ["\(ResourceLabelKeys.plugin)!=machine"]])
        #expect(notMachine.map(\.id) == ["k8s-dev-worker-1", "old-job"])
    }
}
