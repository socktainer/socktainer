import ContainerClient
import Containerization
import Foundation

public func getLinuxDefaultKernelName() async throws -> String {
    let kernel = try await ClientKernel.getDefaultKernel(for: SystemPlatform.current)
    let pathString = kernel.path.path
    let components = pathString.split(separator: "/")
    return components.last.map(String.init) ?? pathString
}

public func stripSubnetFromIP(_ ipAddress: String?) -> String? {
    guard let ipAddress = ipAddress else { return nil }
    return ipAddress.components(separatedBy: "/").first
}
