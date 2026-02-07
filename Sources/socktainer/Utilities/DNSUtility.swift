import ContainerAPIClient
import ContainerNetworkService
import ContainerResource
import Containerization
import Foundation
import Vapor

/// Utility for creating DNS configurations for containers
enum DNSUtility {

    static func createDNSConfiguration(
        dnsServers: [String]?,
        dnsSearch: [String]?,
        dnsOptions: [String]?,
        domainname: String?,
        networks: [AttachmentConfiguration],
    ) async throws -> ContainerConfiguration.DNSConfiguration? {
        let nameservers: [String]
        if let dns = dnsServers, !dns.isEmpty {
            nameservers = dns
        } else {
            nameservers = try await getDefaultNameservers(networks: networks)
        }

        guard !nameservers.isEmpty else {
            return nil
        }

        let domain: String? = {
            if let domainname = domainname, !domainname.isEmpty {
                return domainname
            }
            return nil
        }()

        return ContainerConfiguration.DNSConfiguration(
            nameservers: nameservers,
            domain: domain,
            searchDomains: dnsSearch ?? [],
            options: dnsOptions ?? []
        )
    }

    /// NOTE: This follows Apple container compatible behavior:
    ///       1. Use network gateway IP as DNS server if network is running
    ///       2. Fallback to 1.1.1.1 (Cloudflare DNS) if network unavailable
    private static func getDefaultNameservers(
        networks: [AttachmentConfiguration],
    ) async throws -> [String] {
        // Try to get gateway from first network containing gateway
        for networkConfig in networks {
            do {
                let networksList = try await ClientNetwork.list()
                if let networkState = networksList.first(where: { state in
                    switch state {
                    case .created(let config): return config.id == networkConfig.network
                    case .running(let config, _): return config.id == networkConfig.network
                    }
                }) {
                    if case .running(_, let status) = networkState {
                        let gateway = String(describing: status.ipv4Gateway)
                        return [gateway]
                    }
                }
            } catch {
                continue
            }
        }

        // Fallback to Cloudflare DNS (like Apple container CLI uses 1.1.1.1 as default)
        return ["1.1.1.1"]
    }
}
