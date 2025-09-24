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
