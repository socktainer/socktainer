import Foundation
import Vapor

public struct RESTNetworkSummary: Content {
    public let Name: String
    public let Id: String
    public let Created: String
    public let Scope: String
    public let Driver: String
    public let EnableIPv4: Bool
    public let EnableIPv6: Bool
    public let Internal: Bool
    public let Attachable: Bool
    public let Ingress: Bool
    public let IPAM: NetworkIPAM
    public let Options: [String: String]
    public let Containers: [String: NetworkContainer]?
    public let ConfigFrom: NetworkConfigReference?
    public let Labels: [String: String]
    public let Subnet: String?
    public let Gateway: String?
}
