import Foundation

public enum ContainerWaitCondition: String, CaseIterable, Codable, Sendable {
    case notRunning = "not-running"
    case nextExit = "next-exit"
    case removed = "removed"
    case healthy = "healthy"

    public static let `default`: ContainerWaitCondition = .notRunning
}
