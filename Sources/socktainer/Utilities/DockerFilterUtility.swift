import Foundation
import Vapor

// utility for parsing network filters from query string
struct DockerNetworkFilterUtility {
    // parses network filters from a query string, optionally defaulting to dangling only
    // dangling networks are networks with no containers are attached to them
    static func parseNetworkFilters(filtersParam: String?, defaultDangling: Bool, logger: Logger) throws -> [String: [String]] {
        var filters: [String: Any] = [:]
        var parsedFilters: [String: [String]] = [:]
        if let filtersParam = filtersParam, let data = filtersParam.data(using: .utf8) {
            if let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                filters = decoded

                // Validate keys
                let allowedKeys: Set<String> = ["name", "id", "label", "dangling"]
                let filterKeys = Set(filters.keys)
                if !filterKeys.isSubset(of: allowedKeys) {
                    logger.warning("Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
                    throw Abort(.badRequest, reason: "Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
                }

                for (key, value) in filters {
                    if let dict = value as? [String: Any] {
                        let keys = dict.compactMap { (key, value) in
                            (value as? Bool == true) ? key : nil
                        }
                        if !keys.isEmpty {
                            parsedFilters[key] = keys
                        }
                    } else if let arr = value as? [String] {
                        parsedFilters[key] = arr
                    }
                }
                logger.debug("Decoded filters: \(parsedFilters)")
            } else {
                logger.warning("Failed to decode filters")
            }
        } else if defaultDangling {
            parsedFilters["dangling"] = ["true"]
            logger.debug("No filters provided, defaulting to prune only dangling networks.")
        }
        return parsedFilters
    }
}

// utility for parsing container filters from query string
struct DockerContainerFilterUtility {
    static func parseContainerPruneFilters(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = ["until", "label"]
        var filters: [String: Any] = [:]
        var parsedFilters: [String: [String]] = [:]
        if let filtersParam = filtersParam, let data = filtersParam.data(using: .utf8) {
            if let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                filters = decoded
                // Validate keys
                let filterKeys = Set(filters.keys)
                if !filterKeys.isSubset(of: allowedKeys) {
                    logger.warning("Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
                    throw Abort(.badRequest, reason: "Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
                }
                for (key, value) in filters {
                    if let dict = value as? [String: Any] {
                        let keys = dict.compactMap { (k, v) in
                            (v as? Bool == true) ? k : nil
                        }
                        if !keys.isEmpty {
                            parsedFilters[key] = keys
                        }
                    } else if let arr = value as? [String] {
                        parsedFilters[key] = arr
                    } else if let str = value as? String {
                        parsedFilters[key] = [str]
                    }
                }
                logger.debug("Decoded container prune filters: \(parsedFilters)")
            } else {
                logger.warning("Failed to decode container prune filters")
            }
        }
        return parsedFilters
    }

    static func parseContainerFilters(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = [
            "status",
            "exited",
            "label",
            "name",
            "id",
            "ancestor",
            "before",
            "since",
            "health",
            "volume",
            "expose",
            "health",
            "isolation",
            "is-task",
            "network",
            "publish",
            "since",
        ]
        var filters: [String: Any] = [:]
        var parsedFilters: [String: [String]] = [:]
        if let filtersParam = filtersParam, let data = filtersParam.data(using: .utf8) {
            if let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                filters = decoded
                // Validate keys
                let filterKeys = Set(filters.keys)
                if !filterKeys.isSubset(of: allowedKeys) {
                    logger.warning("Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
                    throw Abort(.badRequest, reason: "Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
                }
                for (key, value) in filters {
                    if key == "label", let dict = value as? [String: Any] {
                        let keys = dict.compactMap { (k, v) in
                            (v as? Bool == true) ? k : nil
                        }
                        if !keys.isEmpty {
                            parsedFilters[key] = keys
                        }
                    } else if let arr = value as? [String] {
                        parsedFilters[key] = arr
                    } else if let str = value as? String {
                        parsedFilters[key] = [str]
                    }
                }
                logger.debug("Decoded filters: \(parsedFilters)")
            } else {
                logger.warning("Failed to decode filters")
            }
        }
        return parsedFilters
    }
}

// utility for parsing volume filters from query string
struct DockerVolumeFilterUtility {
    static func parsePruneFilters(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = ["label", "all"]
        var filters: [String: Any] = [:]
        var parsedFilters: [String: [String]] = [:]
        if let filtersParam = filtersParam, let data = filtersParam.data(using: .utf8) {
            if let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                filters = decoded
                // Validate keys
                let filterKeys = Set(filters.keys)
                if !filterKeys.isSubset(of: allowedKeys) {
                    logger.warning("Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
                    throw Abort(.badRequest, reason: "Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
                }
                for (key, value) in filters {
                    if let dict = value as? [String: Any] {
                        let keys = dict.compactMap { (key, value) in
                            (value as? Bool == true) ? key : nil
                        }
                        if !keys.isEmpty {
                            parsedFilters[key] = keys
                        }
                    } else if let arr = value as? [String] {
                        parsedFilters[key] = arr
                    }
                }
                logger.debug("Decoded filters: \(parsedFilters)")
            } else {
                logger.warning("Failed to decode filters")
            }
        }
        return parsedFilters
    }

    static func parseVolumeFilters(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = ["name", "driver", "label", "dangling"]
        var filters: [String: Any] = [:]
        var parsedFilters: [String: [String]] = [:]
        if let filtersParam = filtersParam, let data = filtersParam.data(using: .utf8) {
            if let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                filters = decoded
                // Validate keys
                let filterKeys = Set(filters.keys)
                if !filterKeys.isSubset(of: allowedKeys) {
                    logger.warning("Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
                    throw Abort(.badRequest, reason: "Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
                }
                for (key, value) in filters {
                    if let dict = value as? [String: Any] {
                        let keys = dict.compactMap { (key, value) in
                            (value as? Bool == true) ? key : nil
                        }
                        if !keys.isEmpty {
                            parsedFilters[key] = keys
                        }
                    } else if let arr = value as? [String] {
                        parsedFilters[key] = arr
                    }
                }
                logger.debug("Decoded filters: \(parsedFilters)")
            } else {
                logger.warning("Failed to decode filters")
            }
        }
        return parsedFilters
    }
}

struct DockerImageFilterUtility {
    static func parseImagePruneFilters(filterParam: String?, logger: Logger) -> [String: [String]] {
        var parsedFilters: [String: [String]] = [:]

        if let filterParam = filterParam {
            if let data = filterParam.data(using: .utf8) {
                do {
                    // First try to parse as generic JSON to see what we got
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        for (key, value) in json {
                            switch key {
                            case "dangling", "label", "until":
                                // Handle dictionary format: {"dangling": {"true": true}}
                                if let dict = value as? [String: Any] {
                                    let keys = dict.compactMap { (k, v) in
                                        (v as? Bool == true) ? k : nil
                                    }
                                    if !keys.isEmpty {
                                        parsedFilters[key] = keys
                                    }
                                }
                                // Handle array format: {"dangling": ["true"]}
                                else if let arr = value as? [String] {
                                    parsedFilters[key] = arr
                                }
                                // Handle single string: {"dangling": "true"}
                                else if let str = value as? String {
                                    parsedFilters[key] = [str]
                                }
                            default:
                                logger.warning("Unknown filter key '\(key)'")
                            }
                        }
                    }
                } catch {
                    logger.warning("Failed to decode filters: \(error)")
                }
            } else {
                logger.warning("Failed to convert filter param to data")
            }
        }

        return parsedFilters
    }
}

// utility for parsing build cache filters from query string
struct DockerBuildFilterUtility {
    static func parseBuildPruneFilters(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        let supportedKeys: Set<String> = ["until", "id", "inuse", "parent", "type", "description", "shared", "private"]
        var filters: [String: Any] = [:]
        var parsedFilters: [String: [String]] = [:]

        if let filtersParam = filtersParam, let data = filtersParam.data(using: .utf8) {
            if let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                filters = decoded

                // Validate keys
                let filterKeys = Set(filters.keys)
                if !filterKeys.isSubset(of: supportedKeys) {
                    let invalid = filterKeys.subtracting(supportedKeys)
                    logger.warning("Invalid filter key(s) found: \(invalid)")
                    throw Abort(.badRequest, reason: "Invalid filter key(s) found: \(invalid)")
                }

                for (key, value) in filters {
                    if let dict = value as? [String: Any] {
                        let keys = dict.compactMap { (k, v) in
                            (v as? Bool == true) ? k : nil
                        }
                        if !keys.isEmpty {
                            parsedFilters[key] = keys
                        }
                    } else if let arr = value as? [String] {
                        parsedFilters[key] = arr
                    } else if let str = value as? String {
                        parsedFilters[key] = [str]
                    }
                }
                logger.info("Parsed build prune filters: \(parsedFilters)")
            } else {
                logger.warning("Failed to decode build prune filters")
            }
        }

        return parsedFilters
    }

    // Parse Docker's "until" filter value and convert to Date
    static func parseUntilFilter(_ untilValue: String) -> Date? {
        let now = Date()

        // Check if it's a duration string (e.g., "24h", "1h30m", "10m")
        if let duration = parseDuration(untilValue) {
            return now.addingTimeInterval(-duration)
        }

        // Check if it's a Unix timestamp
        if let timestamp = TimeInterval(untilValue) {
            return Date(timeIntervalSince1970: timestamp)
        }

        // Try parsing as ISO8601 date
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: untilValue) {
            return date
        }

        // Try parsing as RFC3339
        let rfc3339Formatter = DateFormatter()
        rfc3339Formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        if let date = rfc3339Formatter.date(from: untilValue) {
            return date
        }

        return nil
    }

    // Parse Go-style duration strings (e.g., "24h", "1h30m", "10m")
    private static func parseDuration(_ duration: String) -> TimeInterval? {
        var remainingString = duration
        var totalSeconds: TimeInterval = 0

        let units: [(suffix: String, multiplier: TimeInterval)] = [
            ("d", 86400),
            ("h", 3600),
            ("m", 60),
            ("s", 1),
        ]

        for (suffix, multiplier) in units {
            if let range = remainingString.range(of: suffix) {
                let numberPart = String(remainingString[..<range.lowerBound])
                if let value = TimeInterval(numberPart) {
                    totalSeconds += value * multiplier
                    remainingString = String(remainingString[range.upperBound...])
                }
            }
        }

        return totalSeconds > 0 ? totalSeconds : nil
    }
}
