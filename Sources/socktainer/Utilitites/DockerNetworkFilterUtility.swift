import Foundation
import Vapor

// utility for parsing network filters from query string
struct DockerNetworkFilterUtility {
    // parses network filters from a query string, optionally defaulting to dangling only
    // dangling networks are networks with no containers are attached to them
    static func parseNetworkFilters(filtersParam: String?, defaultDangling: Bool, logger: Logger) -> [String: [String]] {
        var filters: [String: Any] = [:]
        var parsedFilters: [String: [String]] = [:]
        if let filtersParam = filtersParam, let data = filtersParam.data(using: .utf8) {
            if let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                filters = decoded
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
