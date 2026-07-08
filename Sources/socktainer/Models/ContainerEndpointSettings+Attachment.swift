import ContainerResource

extension ContainerEndpointSettings {
    static func live(_ attachment: Attachment) -> ContainerEndpointSettings {
        ContainerEndpointSettings(
            IPAMConfig: nil,
            Links: nil,
            Aliases: nil,
            NetworkID: attachment.network,
            EndpointID: nil,
            Gateway: stripSubnetFromIP(String(describing: attachment.ipv4Gateway)),
            IPAddress: stripSubnetFromIP(String(describing: attachment.ipv4Address)),
            IPPrefixLen: nil,
            IPv6Gateway: nil,
            GlobalIPv6Address: attachment.ipv6Address?.address.description,
            GlobalIPv6PrefixLen: attachment.ipv6Address.map { Int($0.prefix.length) },
            MacAddress: nil,
            DriverOpts: nil
        )
    }

    static func configured(networkID: String) -> ContainerEndpointSettings {
        ContainerEndpointSettings(
            IPAMConfig: nil,
            Links: nil,
            Aliases: nil,
            NetworkID: networkID,
            EndpointID: nil,
            Gateway: nil,
            IPAddress: nil,
            IPPrefixLen: nil,
            IPv6Gateway: nil,
            GlobalIPv6Address: nil,
            GlobalIPv6PrefixLen: nil,
            MacAddress: nil,
            DriverOpts: nil
        )
    }
}
