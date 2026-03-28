import ContainerResource
import Foundation

enum AppleContainerTimestampResolver {
    static let legacyCreationTimestampLabel = "io.github.socktainer.creation-timestamp"

    private static let appSupportURL = URL(
        fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/com.apple.container"
    )
    private static let epoch = Date(timeIntervalSince1970: 0)

    static func containerCreationDate(_ container: ContainerSnapshot) -> Date? {
        if let bundleCreationDate = creationDate(
            at: appSupportURL.appendingPathComponent("containers").appendingPathComponent(container.id)
        ) {
            return bundleCreationDate
        }

        return legacyLabelCreationDate(from: container.configuration.labels)
    }

    static func networkCreationDate(_ networkState: NetworkState) -> Date? {
        if networkState.creationDate > epoch {
            return networkState.creationDate
        }

        let labels: [String: String]
        switch networkState {
        case .created(let config):
            labels = config.labels
        case .running(let config, _):
            labels = config.labels
        }

        return legacyLabelCreationDate(from: labels)
    }

    static func legacyLabelCreationDate(from labels: [String: String]) -> Date? {
        guard let timestampString = labels[legacyCreationTimestampLabel] else {
            return nil
        }

        guard let timestamp = TimeInterval(timestampString) else {
            return nil
        }

        return Date(timeIntervalSince1970: timestamp)
    }

    static func unixTimestampSeconds(_ date: Date?) -> Int64 {
        guard let date else {
            return 0
        }
        return Int64(date.timeIntervalSince1970)
    }

    static func iso8601Date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func unixTimestampSeconds(_ value: String?) -> Int64 {
        unixTimestampSeconds(iso8601Date(value))
    }

    static func iso8601Timestamp(_ date: Date?) -> String {
        guard let date else {
            return "1970-01-01T00:00:00Z"
        }

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func creationDate(at url: URL) -> Date? {
        let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey])
        return resourceValues?.creationDate
    }
}
