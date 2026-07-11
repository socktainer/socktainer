import ContainerAPIClient
import ContainerNetworkClient
import ContainerResource
import ContainerizationExtras
import Foundation
import Logging

protocol ClientNetworkProtocol: Sendable {
    func list(filters: String?, logger: Logger) async throws -> [RESTNetworkSummary]
    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary?
    func delete(id: String, logger: Logger) async throws
    func create(name: String, labels: [String: String], ipv4Subnet: String?, logger: Logger) async throws -> RESTNetworkCreate
}

struct ClientNetworkService: ClientNetworkProtocol {
    private let networkClient = NetworkClient()

    func list(filters: String? = nil, logger: Logger) async throws -> [RESTNetworkSummary] {
        let networksList = try await networkClient.list()
        var allNetworks = networksList.map { RESTNetworkSummary(networkResource: $0) }
        let containerClient = ClientContainerService()
        let allContainers = try await containerClient.list(showAll: true, filters: [:])

        // Map containers to networks
        for i in 0..<allNetworks.count {
            let network = allNetworks[i]
            var containersForNetwork: [String: NetworkContainer] = [:]
            for container in allContainers {
                // Exclude internal Socktainer DNS sidecars from the Docker API view.
                // If CoreDNS shows up as an attached container, docker compose down
                // reports "Resource is still in use" and skips the DELETE /networks/{id}
                // call — preventing our cleanup hook from firing.
                guard !ClientContainerService.isDNSSidecar(container) else {
                    continue
                }
                for attachment in container.networks {
                    if attachment.network == network.Id || attachment.network == network.Name {
                        let nc = NetworkContainer(
                            Name: container.id,
                            EndpointID: nil,  // Apple container doesn't have a matching field
                            MacAddress: nil,  // Apple container doesn't have a matching field
                            IPv4Address: String(describing: attachment.ipv4Address),
                            IPv6Address: nil
                        )
                        containersForNetwork[container.id] = nc
                        logger.debug("Container \(container.id) attached to network \(network.Name) (ID: \(network.Id))")
                    }
                }
            }
            if !containersForNetwork.isEmpty {
                allNetworks[i] = RESTNetworkSummary(
                    Name: network.Name,
                    Id: network.Id,
                    Created: network.Created,
                    Scope: network.Scope,
                    Driver: network.Driver,
                    EnableIPv4: network.EnableIPv4,
                    EnableIPv6: network.EnableIPv6,
                    Internal: network.Internal,
                    Attachable: network.Attachable,
                    Ingress: network.Ingress,
                    IPAM: network.IPAM,
                    Options: network.Options,
                    Containers: containersForNetwork,
                    ConfigFrom: network.ConfigFrom,
                    Labels: network.Labels,
                    Subnet: network.Subnet,
                    Gateway: network.Gateway
                )
            }
        }

        return Self.applyFilters(allNetworks, filters: filters, logger: logger)
    }

    /// Applies Docker network list/prune filters. Multiple values for the same
    /// key OR together (a network matches if it matches any value); different
    /// keys AND together — the same OR/AND combination moby's filters.Args
    /// implements. `label` is the exception: every label filter must match,
    /// as in moby.
    static func applyFilters(_ allNetworks: [RESTNetworkSummary], filters: String?, logger: Logger) -> [RESTNetworkSummary] {
        guard let filters = filters, let data = filters.data(using: .utf8) else { return allNetworks }
        guard let filtersDict = try? JSONDecoder().decode([String: [String]].self, from: data) else { return allNetworks }
        // If filtersDict contains only unknown keys, return []
        let knownKeys: Set<String> = ["dangling", "driver", "id", "label", "name", "scope", "type"]
        let filterKeys = Set(filtersDict.keys)
        if !filterKeys.isEmpty && filterKeys.isDisjoint(with: knownKeys) {
            logger.info("All filter keys are unknown: \(filterKeys). Returning empty result.")
            return []
        }
        return allNetworks.filter { network in
            var excludedReason: String? = nil
            if let danglingArr = filtersDict["dangling"], let danglingStr = danglingArr.first,
                let wantsDangling = MobyBool.parse(danglingStr)
            {
                let isDangling = (network.Containers == nil || network.Containers?.isEmpty == true)
                if wantsDangling != isDangling {
                    excludedReason = "dangling mismatch"
                }
            }
            if let driverArr = filtersDict["driver"], !driverArr.isEmpty {
                if !driverArr.contains(where: { network.Driver.caseInsensitiveCompare($0) == .orderedSame }) {
                    excludedReason = "driver mismatch"
                }
            }
            if let idArr = filtersDict["id"], !idArr.isEmpty {
                if !idArr.contains(where: { network.Id.localizedCaseInsensitiveContains($0) }) {
                    excludedReason = "id mismatch"
                }
            }
            if let labels = filtersDict["label"] {
                for label in labels {
                    if label.contains("=") {
                        let parts = label.split(separator: "=", maxSplits: 1)
                        let key = String(parts[0])
                        let value = String(parts[1])
                        if LabelNormalization.filterValue(in: network.Labels, forKey: key) != value {
                            excludedReason = "label key=value mismatch"
                        }
                    } else {
                        if !LabelNormalization.filterContainsKey(label, in: network.Labels) {
                            excludedReason = "label key missing"
                        }
                    }
                }
            }
            if let nameArr = filtersDict["name"], !nameArr.isEmpty {
                if !nameArr.contains(where: { network.Name.localizedCaseInsensitiveContains($0) }) {
                    excludedReason = "name mismatch"
                }
            }
            if let scopeArr = filtersDict["scope"], !scopeArr.isEmpty {
                if !scopeArr.contains(where: { network.Scope.localizedCaseInsensitiveContains($0) }) {
                    excludedReason = "scope mismatch"
                }
            }
            if let typeArr = filtersDict["type"], !typeArr.isEmpty {
                let isCustom = network.Driver != "bridge" && network.Driver != "host" && network.Driver != "null"
                if !typeArr.contains(where: { ($0 == "custom" && isCustom) || ($0 == "builtin" && !isCustom) }) {
                    excludedReason = "type mismatch"
                }
            }
            if let reason = excludedReason {
                logger.debug("Excluding network \(network.Name) (ID: \(network.Id)) due to: \(reason)")
                return false
            }
            return true
        }
    }

    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary? {
        let networks = try await list(logger: logger)
        return networks.first { $0.Id == id || $0.Name == id }
    }

    func delete(id: String, logger: Logger) async throws {
        try await networkClient.delete(id: id)
        logger.debug("Deleted network with id: \(id)")
    }

    func create(name: String, labels: [String: String], ipv4Subnet: String?, logger: Logger) async throws -> RESTNetworkCreate {
        // NOTE: We will only create networks of type NAT for the time being (mimic the container CLI)
        let pinnedSubnet = try ipv4Subnet.map { try CIDRv4($0) }
        let configuration = try NetworkConfiguration(
            name: name,
            mode: NetworkMode.nat,
            ipv4Subnet: pinnedSubnet,
            labels: ResourceLabels(labels),
            plugin: "container-network-vmnet"
        )
        _ = try await networkClient.create(configuration: configuration)
        logger.debug("Created network with id: \(configuration.name)")
        return RESTNetworkCreate(Id: configuration.name, Warning: "")
    }
}

extension RESTNetworkSummary {
    init(networkResource: NetworkResource) {
        let id = networkResource.configuration.name
        let driver = String(describing: networkResource.configuration.mode)
        let options: [String: String] = [:]  // Not provided by Apple container
        let labels = LabelNormalization.restore(networkResource.configuration.labels.dictionary)
        let subnet =
            networkResource.configuration.ipv4Subnet.map { String(describing: $0) }
            ?? String(describing: networkResource.status.ipv4Subnet)
        let gateway = String(describing: networkResource.status.ipv4Gateway)
        // Non-nil once the network plugin has assigned an IPv6 prefix (vmnet NAT66
        // auto-prefix, or an explicit one from `container network create --subnet-v6`).
        let hasIPv6Prefix = networkResource.status.ipv6Subnet != nil

        let createdTimestamp = AppleContainerTimestampResolver.iso8601Timestamp(
            AppleContainerTimestampResolver.networkCreationDate(networkResource)
        )

        self.init(
            Name: id,
            Id: id,
            Created: createdTimestamp,
            Scope: "local",  // We will always use "local", other modes are not available
            Driver: driver,
            EnableIPv4: true,
            EnableIPv6: hasIPv6Prefix,
            // NOTE: Apple container has no mechanism to set networks as internal
            Internal: false,
            Attachable: false,
            Ingress: false,  // Only applicable for Swarm
            IPAM: NetworkIPAM(
                Driver: "default",
                Config: subnet.isEmpty ? [] : [NetworkIPAMConfig(Subnet: subnet, IPRange: nil, Gateway: gateway, AuxiliaryAddresses: nil)]
            ),
            Options: options,
            Containers: nil,
            ConfigFrom: nil,
            Labels: labels,
            Subnet: subnet,
            Gateway: gateway
        )
    }
}
