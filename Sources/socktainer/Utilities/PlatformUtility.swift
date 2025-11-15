import ContainerClient
import Containerization
import ContainerizationOCI
import Foundation

public typealias Platform = ContainerizationOCI.Platform

public func currentPlatform() -> Platform {
    Platform.current
}

public func platformOrThrow(_ platformString: String) throws -> Platform {
    try Platform(from: platformString)
}
