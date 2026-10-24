import ContainerResource

extension ContainerConfiguration {
    /// The aliases per network attachment. Apple's live `Attachment` carries none — only
    /// the persisted configuration does — and duplicate network names keep the first entry
    /// instead of trapping.
    var endpointAliasesByNetwork: [String: [String]] {
        Dictionary(
            networks.map { ($0.network, $0.options.aliases) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

extension ContainerEndpointSettings {
    static func live(_ attachment: Attachment, aliases: [String]? = nil) -> ContainerEndpointSettings {
        ContainerEndpointSettings(
            IPAMConfig: nil,
            Links: nil,
            Aliases: nonEmpty(aliases),
            NetworkID: attachment.network,
            EndpointID: nil,
            Gateway: stripSubnetFromIP(String(describing: attachment.ipv4Gateway)),
            IPAddress: stripSubnetFromIP(String(describing: attachment.ipv4Address)),
            IPPrefixLen: Int(attachment.ipv4Address.prefix.length),
            IPv6Gateway: nil,
            GlobalIPv6Address: attachment.ipv6Address?.address.description,
            GlobalIPv6PrefixLen: attachment.ipv6Address.map { Int($0.prefix.length) },
            MacAddress: nil,
            DriverOpts: nil
        )
    }

    static func configured(networkID: String, aliases: [String]? = nil) -> ContainerEndpointSettings {
        ContainerEndpointSettings(
            IPAMConfig: nil,
            Links: nil,
            Aliases: nonEmpty(aliases),
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

    /// Docker clients read `Aliases` as a list of names; emitting `[]` for an
    /// attachment without aliases is noise, so an empty list becomes absent.
    private static func nonEmpty(_ aliases: [String]?) -> [String]? {
        guard let aliases, !aliases.isEmpty else { return nil }
        return aliases
    }
}
