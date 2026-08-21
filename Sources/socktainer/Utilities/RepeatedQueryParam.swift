import Foundation

/// Recovers every value of a repeated query parameter from a raw query string.
///
/// Real podman clients send several build/manifest options as the SAME query key
/// repeated once per value (e.g. `platform=linux/arm64&platform=linux/amd64`,
/// `images=foo&images=bar`) rather than one comma-joined or bracket-array value.
/// `Vapor.Content` decoding a repeated key into a scalar field silently keeps only
/// the last occurrence — this parses the raw, still-percent-encoded query string
/// (e.g. `req.url.query`) directly to recover every value.
///
/// Parses `&`/`=` manually rather than via `URLComponents.percentEncodedQuery` —
/// that setter validates its input and can trap on a malformed percent-escape in
/// this client-controlled string, which would be a crash, not a graceful decode
/// failure. A key or value that fails to percent-decode is used as-is instead of
/// being dropped, matching this function's existing "never throws" contract.
func allQueryValues(named name: String, from queryString: String?) -> [String] {
    guard let queryString, !queryString.isEmpty else { return [] }
    return queryString.split(separator: "&").compactMap { pair -> String? in
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawKey = parts.first else { return nil }
        // `+` means space in form-encoded query strings; `removingPercentEncoding` only
        // handles `%XX`, so translate it first to match Vapor's own query decoding.
        let keySource = String(rawKey).replacingOccurrences(of: "+", with: " ")
        let key = keySource.removingPercentEncoding ?? keySource
        guard key == name else { return nil }
        guard parts.count > 1 else { return "" }
        let valueSource = String(parts[1]).replacingOccurrences(of: "+", with: " ")
        return valueSource.removingPercentEncoding ?? valueSource
    }
}
