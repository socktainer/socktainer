import Foundation

public func stripSubnetFromIP(_ address: String?) -> String? {
    address?.split(separator: "/", maxSplits: 1).first.map(String.init)
}
