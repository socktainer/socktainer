import ContainerizationError
import Foundation
import Logging

enum BuildctlUtility {
    static let executable = "/usr/bin/buildctl"

    struct Command {
        let executable: String
        let arguments: [String]

        var commandLine: String {
            ([self.executable] + arguments).joined(separator: " ")
        }
    }

    struct PruneRecord: Decodable {
        let id: String?
        let size: Int64?

        enum CodingKeys: String, CodingKey {
            case id
            case size
            case idLegacy = "ID"
            case sizeLegacy = "Size"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id =
                try container.decodeIfPresent(String.self, forKey: .id)
                ?? container.decodeIfPresent(String.self, forKey: .idLegacy)
            size =
                try container.decodeIfPresent(Int64.self, forKey: .size)
                ?? container.decodeIfPresent(Int64.self, forKey: .sizeLegacy)
        }
    }

    struct DuRecord: Decodable {
        let id: String?
        let parents: [String]?
        let recordType: String?
        let recordDescription: String?
        let inUse: Bool?
        let shared: Bool?
        let size: Int64?
        let createdAt: String?
        let lastUsedAt: String?
        let usageCount: Int?

        init(
            id: String?,
            parents: [String]?,
            recordType: String?,
            recordDescription: String?,
            inUse: Bool?,
            shared: Bool?,
            size: Int64?,
            createdAt: String?,
            lastUsedAt: String?,
            usageCount: Int?
        ) {
            self.id = id
            self.parents = parents
            self.recordType = recordType
            self.recordDescription = recordDescription
            self.inUse = inUse
            self.shared = shared
            self.size = size
            self.createdAt = createdAt
            self.lastUsedAt = lastUsedAt
            self.usageCount = usageCount
        }

        enum CodingKeys: String, CodingKey {
            case id
            case parents
            case recordType = "type"
            case recordDescription = "description"
            case inUse
            case shared
            case size
            case createdAt
            case lastUsedAt
            case usageCount

            case idLegacy = "ID"
            case parentsLegacy = "Parents"
            case typeLegacy = "Type"
            case descriptionLegacy = "Description"
            case inUseLegacy = "InUse"
            case sharedLegacy = "Shared"
            case sizeLegacy = "Size"
            case createdAtLegacy = "CreatedAt"
            case lastUsedAtLegacy = "LastUsedAt"
            case usageCountLegacy = "UsageCount"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id =
                try container.decodeIfPresent(String.self, forKey: .id)
                ?? container.decodeIfPresent(String.self, forKey: .idLegacy)
            parents =
                try container.decodeIfPresent([String].self, forKey: .parents)
                ?? container.decodeIfPresent([String].self, forKey: .parentsLegacy)
            recordType =
                try container.decodeIfPresent(String.self, forKey: .recordType)
                ?? container.decodeIfPresent(String.self, forKey: .typeLegacy)
            recordDescription =
                try container.decodeIfPresent(String.self, forKey: .recordDescription)
                ?? container.decodeIfPresent(String.self, forKey: .descriptionLegacy)
            inUse =
                try container.decodeIfPresent(Bool.self, forKey: .inUse)
                ?? container.decodeIfPresent(Bool.self, forKey: .inUseLegacy)
            shared =
                try container.decodeIfPresent(Bool.self, forKey: .shared)
                ?? container.decodeIfPresent(Bool.self, forKey: .sharedLegacy)
            size =
                try container.decodeIfPresent(Int64.self, forKey: .size)
                ?? container.decodeIfPresent(Int64.self, forKey: .sizeLegacy)
            createdAt =
                try container.decodeIfPresent(String.self, forKey: .createdAt)
                ?? container.decodeIfPresent(String.self, forKey: .createdAtLegacy)
            lastUsedAt =
                try container.decodeIfPresent(String.self, forKey: .lastUsedAt)
                ?? container.decodeIfPresent(String.self, forKey: .lastUsedAtLegacy)
            usageCount =
                try container.decodeIfPresent(Int.self, forKey: .usageCount)
                ?? container.decodeIfPresent(Int.self, forKey: .usageCountLegacy)
        }
    }

    static func pruneCommand(from request: BuilderPruneRequest) throws -> Command {
        var arguments = [
            "--addr", "unix:///run/buildkit/buildkitd.sock",
            "prune",
            "--format", "{{json .}}",
        ]

        if request.all {
            arguments.append("--all")
        }

        if let keepStorageBytes = request.maxUsedSpace ?? request.keepStorage {
            arguments.append(contentsOf: ["--keep-storage", megabytesString(keepStorageBytes)])
        }

        if let reservedBytes = request.reservedSpace {
            arguments.append(contentsOf: ["--keep-storage-min", megabytesString(reservedBytes)])
        }

        if let minFreeBytes = request.minFreeSpace {
            arguments.append(contentsOf: ["--free-storage", megabytesString(minFreeBytes)])
        }

        if let untilValues = request.filters["until"], !untilValues.isEmpty {
            guard untilValues.count == 1 else {
                throw ContainerizationError(.invalidArgument, message: "build prune filter 'until' expects exactly one value")
            }
            let keepDuration = try keepDurationString(from: untilValues[0])
            arguments.append(contentsOf: ["--keep-duration", keepDuration])
        }

        for filter in toBuildkitFilters(request.filters) {
            arguments.append(contentsOf: ["--filter", filter])
        }

        return Command(executable: executable, arguments: arguments)
    }

    static func duCommand() -> Command {
        var arguments = [
            "--addr", "unix:///run/buildkit/buildkitd.sock",
            "du",
            "--format=json",
        ]
        return Command(executable: executable, arguments: arguments)
    }

    static func parsePruneOutput(_ output: String, logger: Logger) -> [PruneRecord] {
        var results: [PruneRecord] = []

        for line in output.split(whereSeparator: \Character.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.first == "{" else {
                continue
            }
            guard let data = trimmed.data(using: .utf8) else {
                continue
            }
            do {
                let item = try JSONDecoder().decode(PruneRecord.self, from: data)
                results.append(item)
            } catch {
                logger.debug("Failed to decode buildctl prune output line")
            }
        }

        return results
    }

    static func parseDuOutput(_ output: String, logger: Logger) -> [DuRecord] {
        guard let data = output.data(using: .utf8) else {
            return []
        }
        do {
            return try JSONDecoder().decode([DuRecord].self, from: data)
        } catch {
            logger.debug("Failed to decode buildctl du JSON output: \(error)")
            return []
        }
    }

    private static func toBuildkitFilters(_ filters: [String: [String]]) -> [String] {
        var result: [String] = []

        for (key, values) in filters {
            guard key != "until" else {
                continue
            }

            if values.isEmpty {
                result.append(key)
                continue
            }

            for value in values {
                if key == "id" {
                    result.append("\(key)~=\(value)")
                } else {
                    result.append("\(key)==\(value)")
                }
            }
        }

        return result
    }

    private static func keepDurationString(from untilValue: String) throws -> String {
        if parseDuration(untilValue) != nil {
            return untilValue
        }

        guard let untilDate = DockerBuildFilterUtility.parseUntilFilter(untilValue) else {
            throw ContainerizationError(.invalidArgument, message: "Invalid build prune filter 'until': \(untilValue)")
        }

        let seconds = max(0, Int(Date().timeIntervalSince(untilDate)))
        return "\(seconds)s"
    }

    private static func megabytesString(_ bytes: Int64) -> String {
        String(Double(bytes) / 1_000_000.0)
    }

    private static func parseDuration(_ duration: String) -> TimeInterval? {
        var remaining = duration
        var totalSeconds: TimeInterval = 0
        let units: [(String, TimeInterval)] = [("d", 86_400), ("h", 3_600), ("m", 60), ("s", 1)]

        for (suffix, multiplier) in units {
            while let range = remaining.range(of: suffix) {
                let number = String(remaining[..<range.lowerBound])
                guard let value = TimeInterval(number) else {
                    return nil
                }
                totalSeconds += value * multiplier
                remaining = String(remaining[range.upperBound...])
            }
        }

        return totalSeconds > 0 ? totalSeconds : nil
    }
}
