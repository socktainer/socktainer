import ContainerAPIClient
import Containerization
import ContainerizationOCI
import Foundation
import Vapor

public typealias Platform = ContainerizationOCI.Platform

public func currentPlatform() -> Platform {
    Platform.current
}

public func platformOrThrow(_ platformString: String) throws -> Platform {
    let trimmed = platformString.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmed.first == "{" {
        guard let data = trimmed.data(using: .utf8) else {
            throw Abort(.badRequest, reason: "invalid JSON-encoded OCI platform object")
        }

        do {
            return try JSONDecoder().decode(Platform.self, from: data)
        } catch {
            throw Abort(.badRequest, reason: "invalid JSON-encoded OCI platform object")
        }
    }

    return try Platform(from: trimmed)
}

public func requestedOrDefaultPlatform(_ requestedPlatform: Platform?) -> Platform {
    requestedPlatform ?? Platform.current
}

public func preferredPlatformMatches(
    _ leftPlatform: Platform?,
    over rightPlatform: Platform?,
    preferredPlatform: Platform
) -> Bool {
    let leftExactMatch = leftPlatform == preferredPlatform
    let rightExactMatch = rightPlatform == preferredPlatform
    if leftExactMatch != rightExactMatch {
        return leftExactMatch
    }

    let leftArchitectureMatch = leftPlatform?.architecture == preferredPlatform.architecture
    let rightArchitectureMatch = rightPlatform?.architecture == preferredPlatform.architecture
    if leftArchitectureMatch != rightArchitectureMatch {
        return leftArchitectureMatch
    }

    let leftOSMatch = leftPlatform?.os == preferredPlatform.os
    let rightOSMatch = rightPlatform?.os == preferredPlatform.os
    if leftOSMatch != rightOSMatch {
        return leftOSMatch
    }

    return false
}
