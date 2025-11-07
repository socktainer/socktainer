import ContainerClient
import ContainerNetworkService
import Foundation
import Logging

protocol ClientNetworkProtocol: Sendable {
    func list(filters: String?, logger: Logger) async throws -> [RESTNetworkSummary]
    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary?
    func delete(id: String, logger: Logger) async throws
    func create(name: String, labels: [String: String], logger: Logger) async throws -> RESTNetworkCreate
}

struct ClientNetworkService: ClientNetworkProtocol {
    func list(filters: String? = nil, logger: Logger) async throws -> [RESTNetworkSummary] {
        let networksList = try await ClientNetwork.list()
        var allNetworks = networksList.map { RESTNetworkSummary(networkState: $0) }
        let containerClient = ClientContainerService()
        let allContainers = try await containerClient.list(showAll: true, filters: [:])

        // Map containers to networks
        for i in 0..<allNetworks.count {
            let network = allNetworks[i]
            var containersForNetwork: [String: NetworkContainer] = [:]
            for container in allContainers {
                for attachment in container.networks {
                    if attachment.network == network.Id || attachment.network == network.Name {
                        let nc = NetworkContainer(
                            Name: container.id,
                            EndpointID: nil,  // Apple container doesn't have a matching field
                            MacAddress: nil,  // Apple container doesn't have a matching field
                            IPv4Address: attachment.address,
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
            if let danglingArr = filtersDict["dangling"], let danglingStr = danglingArr.first {
                let isDangling = (network.Containers == nil || network.Containers?.isEmpty == true)
                if (danglingStr == "true" && !isDangling) || (danglingStr == "false" && isDangling) {
                    excludedReason = "dangling mismatch"
                }
            }
            if let driverArr = filtersDict["driver"], let driver = driverArr.first {
                if network.Driver.caseInsensitiveCompare(driver) != ComparisonResult.orderedSame { excludedReason = "driver mismatch" }
            }
            if let idArr = filtersDict["id"], let id = idArr.first {
                if !network.Id.localizedCaseInsensitiveContains(id) { excludedReason = "id mismatch" }
            }
            if let labels = filtersDict["label"] {
                for label in labels {
                    if label.contains("=") {
                        let parts = label.split(separator: "=", maxSplits: 1)
                        let key = String(parts[0])
                        let value = String(parts[1])
                        if network.Labels[key] != value { excludedReason = "label key=value mismatch" }
                    } else {
                        if network.Labels[label] == nil { excludedReason = "label key missing" }
                    }
                }
            }
            if let nameArr = filtersDict["name"], let name = nameArr.first {
                if !network.Name.localizedCaseInsensitiveContains(name) { excludedReason = "name mismatch" }
            }
            if let scopeArr = filtersDict["scope"], let scope = scopeArr.first {
                if !network.Scope.localizedCaseInsensitiveContains(scope) { excludedReason = "scope mismatch" }
            }
            if let typeArr = filtersDict["type"], let type = typeArr.first {
                let isCustom = network.Driver != "bridge" && network.Driver != "host" && network.Driver != "null"
                if type == "custom" && !isCustom { excludedReason = "type custom mismatch" }
                if type == "builtin" && isCustom { excludedReason = "type builtin mismatch" }
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
        try await ClientNetwork.delete(id: id)
        logger.debug("Deleted network with id: \(id)")
    }

    func create(name: String, labels: [String: String], logger: Logger) async throws -> RESTNetworkCreate {
        // NOTE: We will only create networks of type NAT for the time being (mimic the container CLI)
        // NOTE: [WORKAROUND] to include creation timestamp since it is not handled by Apple Container
        //       https://github.com/apple/container/issues/665
        var mutableLabels = labels
        mutableLabels["io.github.socktainer.creation-timestamp"] = String(Date().timeIntervalSince1970)
        let configuration = try ContainerNetworkService.NetworkConfiguration(id: name, mode: .nat, labels: mutableLabels)
        let state = try await ClientNetwork.create(configuration: configuration)
        logger.debug("Created network with id: \(configuration.id)")
        return RESTNetworkCreate(Id: configuration.id, Warning: "")
    }
}

extension RESTNetworkSummary {
    init(networkState: NetworkState) {
        let id: String
        let driver: String
        let options: [String: String] = [:]  // Not provided by Apple container
        let labels: [String: String]
        var subnet: String? = nil
        var gateway: String? = nil

        switch networkState {
        case .created(let config):
            id = config.id
            driver = String(describing: config.mode)
            subnet = config.subnet
            labels = config.labels
        case .running(let config, let status):
            id = config.id
            driver = String(describing: config.mode)
            subnet = config.subnet ?? status.address
            gateway = status.gateway
            labels = config.labels
        }

        let createdTimestamp: String
        if let timestampStr = labels["io.github.socktainer.creation-timestamp"],
            let timestamp = Double(timestampStr)
        {
            let date = Date(timeIntervalSince1970: timestamp)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            createdTimestamp = formatter.string(from: date)
        } else {
            createdTimestamp = "1970-01-01T00:00:00Z"
        }

        self.init(
            Name: id,
            Id: id,
            Created: createdTimestamp,
            Scope: "local",  // We will always use "local", other modes are not available
            Driver: driver,
            EnableIPv4: true,
            // NOTE: IPv6 is not used in Apple container
            //       https://github.com/apple/container/issues/460
            EnableIPv6: false,
            // NOTE: IPv6 is not used in Apple container
            //       https://github.com/apple/container/issues/460
            // NOTE: Apple container has no mechanism to set networks as internal
            Internal: false,
            Attachable: false,
            Ingress: false,  // Only applicable for Swarm
            IPAM: NetworkIPAM(Driver: "", Config: []),  // Currently, there are no IPAM capabilities
            Options: options,
            Containers: nil,
            ConfigFrom: nil,
            Labels: labels,
            Subnet: subnet,
            Gateway: gateway
        )
    }
}
