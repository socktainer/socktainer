import Foundation
import Logging

/// Handles normalization of Docker label keys to comply with Apple Container's
/// stricter validation rules, while preserving original keys transparently so
/// that `docker inspect` and filter lookups return exactly what the client sent.
///
/// Apple Container only accepts keys matching `[a-z0-9](?:[a-z0-9\-\.\/]*[a-z0-9])?`
/// (Docker format) or the OCI format which additionally allows `/`.
/// Docker clients routinely send mixed-case keys (e.g. `org.testcontainers.sessionId`)
/// that would otherwise cause a 500 error.
enum LabelNormalization {

    /// Internal label used to store the reverse mapping normalized → original key.
    /// Stripped from all Docker API responses so it is invisible to clients.
    static let mappingKey = "socktainer.label-original-keys"

    private static let log = Logger(label: "socktainer.labels")

    // MARK: - Normalization

    /// Normalizes a single label key. Also used when comparing filter keys so
    /// both sides of a label filter lookup are on equal footing.
    ///
    /// Single-pass O(n) normalization:
    ///   1. Lowercase + underscore → hyphen on each character
    ///   2. Drop characters outside `[a-z0-9-./]`
    ///   3. Collapse any run of consecutive separators (including mixed `-./`) to the first one
    ///   4. Strip leading and trailing separators
    static func sanitizeKey(_ key: String) -> String {
        let separators: Set<Character> = ["-", ".", "/"]
        let allowedChars: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz0123456789").union(separators)

        var output: [Character] = []
        // Initialized to `true` so any leading separators are skipped without a second trim pass.
        var prevIsSeparator = true

        for char in key.lowercased() {
            let normalized: Character = char == "_" ? "-" : char
            guard allowedChars.contains(normalized) else { continue }
            let isSeparator = separators.contains(normalized)
            if isSeparator && prevIsSeparator { continue }
            output.append(normalized)
            prevIsSeparator = isSeparator
        }

        // Trim any trailing separator left by the loop.
        while let last = output.last, separators.contains(last) {
            output.removeLast()
        }

        return String(output)
    }

    /// Normalizes all keys in a label dict. Keys that are already valid pass through
    /// unchanged. Keys that become empty after normalization are dropped with a WARNING log.
    /// A WARNING is also logged when two distinct original keys normalize to the same string
    /// (last value wins, earlier value is silently lost without this warning).
    static func sanitize(_ labels: [String: String]) -> [String: String] {
        var normalizedLabels: [String: String] = [:]
        for (key, value) in labels {
            let normalizedKey = sanitizeKey(key)
            // Empty check is unconditional: covers both originally-empty keys ("" → "")
            // and keys that become empty after normalization.
            guard !normalizedKey.isEmpty else {
                log.warning(
                    "Label key dropped — empty after normalization for Apple Container compatibility",
                    metadata: ["original": "\(key)"]
                )
                continue
            }
            if normalizedKey != key {
                log.info(
                    "Label key normalized for Apple Container compatibility",
                    metadata: ["original": "\(key)", "normalized": "\(normalizedKey)"]
                )
            }
            if normalizedLabels[normalizedKey] != nil {
                log.warning(
                    "Label key collision — two keys normalized to the same string, last value wins",
                    metadata: ["normalized-key": "\(normalizedKey)", "value-kept": "\(value)"]
                )
            }
            normalizedLabels[normalizedKey] = value
        }
        return normalizedLabels
    }

    /// Returns true if the labels dict contains the reserved internal mapping key.
    /// Create routes must reject such inputs to prevent silent data loss.
    static func containsReservedKey(_ labels: [String: String]) -> Bool {
        labels[mappingKey] != nil
    }

    // MARK: - Mapping: build and restore

    /// Builds a JSON mapping of normalized key → original key for all keys that changed.
    /// Returns nil when no keys needed normalization (nothing to store).
    static func buildMapping(_ original: [String: String]) -> String? {
        var normalizedToOriginal: [String: String] = [:]
        for originalKey in original.keys {
            let normalizedKey = sanitizeKey(originalKey)
            guard normalizedKey != originalKey, !normalizedKey.isEmpty else { continue }
            normalizedToOriginal[normalizedKey] = originalKey
        }
        guard !normalizedToOriginal.isEmpty,
            let jsonData = try? JSONEncoder().encode(normalizedToOriginal),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else { return nil }
        return jsonString
    }

    // MARK: - Filter helpers

    /// Looks up a label value using both the filter key as-is and its normalized form.
    /// Handles resources with restored original keys (new) and those with only normalized
    /// keys stored (created before this feature).
    static func filterValue(in labels: [String: String], forKey filterKey: String) -> String? {
        labels[filterKey] ?? labels[sanitizeKey(filterKey)]
    }

    /// Returns true if the labels dict contains the given filter key (original or normalized).
    static func filterContainsKey(_ filterKey: String, in labels: [String: String]) -> Bool {
        labels[filterKey] != nil || labels[sanitizeKey(filterKey)] != nil
    }

    /// Restores original label keys using the hidden mapping label, then strips it.
    /// Resources created before this feature have no mapping → returns labels unchanged
    /// (the mapping key is always stripped regardless).
    static func restore(_ labels: [String: String]) -> [String: String] {
        var labelsWithoutMappingKey = labels
        labelsWithoutMappingKey.removeValue(forKey: mappingKey)

        guard let mappingJSON = labels[mappingKey],
            let mappingData = mappingJSON.data(using: .utf8),
            let normalizedToOriginal = try? JSONDecoder().decode([String: String].self, from: mappingData)
        else { return labelsWithoutMappingKey }

        var restoredLabels: [String: String] = [:]
        for (normalizedKey, value) in labelsWithoutMappingKey {
            let originalKey = normalizedToOriginal[normalizedKey] ?? normalizedKey
            restoredLabels[originalKey] = value
        }
        return restoredLabels
    }
}
