import ContainerAPIClient
import Containerization
import ContainerizationOCI
import Foundation
import Vapor

public typealias Platform = ContainerizationOCI.Platform

public func currentPlatform() -> Platform {
    Platform.current
}

/// Docker's `GET /info` reports `Architecture` in the `uname -m` convention
/// (`aarch64`, `x86_64`), not the OCI/GOARCH convention (`arm64`, `amd64`) that
/// `Platform.current.architecture` returns. Clients that key off `/info`
/// Architecture (e.g. MiniStack's Lambda arch detection) reject `arm64`. Map to the
/// Docker/uname value so socktainer matches real Docker on Apple Silicon.
public func dockerInfoArchitecture(_ ociArchitecture: String) -> String {
    switch ociArchitecture {
    case "arm64", "aarch64": return "aarch64"
    case "amd64", "x86_64": return "x86_64"
    default: return ociArchitecture
    }
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
