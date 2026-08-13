import Containerization
import ContainerizationExtras
import Darwin
import Foundation
import vmnet

enum NativeVmnetPortRange {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var selectedBase: Int?
    }

    private static let state = State()
    static let rangeSize = 32
    private static let firstPort = 20_000
    private static let rangeCount = (Int(UInt16.max) - firstPort + 1) / rangeSize

    static var ports: ClosedRange<Int> {
        let base = state.lock.withLock { state.selectedBase ?? candidates[0] }
        return base...(base + rangeSize - 1)
    }

    static var candidates: [Int] {
        let preferredIndex = Int(ProcessInfo.processInfo.processIdentifier) % rangeCount
        return (0..<rangeCount).map {
            firstPort + ((preferredIndex + $0) % rangeCount) * rangeSize
        }
    }

    static func select(_ base: Int) {
        state.lock.withLock { state.selectedBase = base }
    }
}

@available(macOS 26.0, *)
struct NativeVmnetNetwork {
    let interface: any Containerization.Interface
    let gateway: IPv4Address

    init() throws {
        let preferredSubnet = Int(ProcessInfo.processInfo.processIdentifier) % 240
        for (attempt, portBase) in NativeVmnetPortRange.candidates.enumerated() {
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

            var rulesSucceeded = true
            for port in portBase..<(portBase + NativeVmnetPortRange.rangeSize) {
                if vmnet_network_configuration_add_port_forwarding_rule(
                    configuration,
                    UInt8(IPPROTO_TCP),
                    sa_family_t(AF_INET),
                    UInt16(port),
                    UInt16(port),
                    &internalAddress
                ) != .VMNET_SUCCESS {
                    rulesSucceeded = false
                    break
                }
            }
            guard rulesSucceeded,
                let reference = vmnet_network_create(configuration, &status),
                status == .VMNET_SUCCESS
            else {
                continue
            }

            let address = try CIDRv4("\(addressText)/24")
            let gateway = try IPv4Address(gatewayText)
            NativeVmnetPortRange.select(portBase)
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
