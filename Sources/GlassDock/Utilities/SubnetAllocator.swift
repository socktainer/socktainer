enum SubnetAllocator {
    private static let networkPrefix = "192.168"
    private static let lowestThirdOctet = 16
    private static let highestThirdOctet = 254

    static func nextFreeSubnet(usedSubnets: [String], excluded: Set<Int> = []) -> String? {
        let taken = excluded.union(usedSubnets.compactMap(thirdOctet))
        return stride(from: highestThirdOctet, through: lowestThirdOctet, by: -1)
            .first { !taken.contains($0) }
            .map { "\(networkPrefix).\($0).0/24" }
    }

    static func thirdOctet(of cidrOrAddress: String) -> Int? {
        let octets = cidrOrAddress.prefix { $0 != "/" }.split(separator: ".")
        guard octets.count >= 4,
            octets.prefix(2).joined(separator: ".") == networkPrefix,
            let third = Int(octets[2])
        else { return nil }
        return third
    }
}
