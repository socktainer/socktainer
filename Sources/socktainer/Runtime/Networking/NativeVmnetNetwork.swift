import Containerization
import ContainerizationExtras
import Darwin
import Foundation
import vmnet

enum PublishedPortProxyRange {
    static let ports = 20_000...Int(UInt16.max)
}

@available(macOS 26.0, *)
struct NativeVmnetNetwork {
    let interface: any Containerization.Interface
    let gateway: IPv4Address

    init() throws {
        let preferredSubnet = Int(ProcessInfo.processInfo.processIdentifier) % 240
        for attempt in 0..<240 {
            var status: vmnet_return_t = .VMNET_FAILURE
            guard let configuration = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
                continue
            }
            vmnet_network_configuration_disable_dhcp(configuration)

            let subnetOctet = 10 + ((preferredSubnet + attempt) % 240)
            let addressText = "192.168.\(subnetOctet).2"
            let gatewayText = "192.168.\(subnetOctet).1"
            var subnet = in_addr()
            var mask = in_addr()
            var internalAddress = in_addr()
            guard inet_pton(AF_INET, gatewayText, &subnet) == 1,
                inet_pton(AF_INET, "255.255.255.0", &mask) == 1,
                inet_pton(AF_INET, addressText, &internalAddress) == 1,
                vmnet_network_configuration_set_ipv4_subnet(configuration, &subnet, &mask) == .VMNET_SUCCESS
            else {
                continue
            }

            guard let reference = vmnet_network_create(configuration, &status),
                status == .VMNET_SUCCESS
            else {
                continue
            }

            let address = try CIDRv4("\(addressText)/24")
            let gateway = try IPv4Address(gatewayText)
            self.gateway = gateway
            self.interface = NATNetworkInterface(
                ipv4Address: address,
                ipv4Gateway: gateway,
                reference: reference
            )
            return
        }
        throw DirectVZEngineControllerError.interfaceUnavailable
    }
}
