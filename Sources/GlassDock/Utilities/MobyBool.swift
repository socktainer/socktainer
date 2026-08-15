/// Docker clients express booleans two different ways, and moby parses them
/// with two different rules — mirrored here so every route agrees with dockerd.
enum MobyBool {
    /// Filter values: Go's strconv.ParseBool. Anything else is invalid and
    /// callers should reject it.
    static func parse(_ value: String) -> Bool? {
        switch value {
        case "1", "t", "T", "TRUE", "true", "True": return true
        case "0", "f", "F", "FALSE", "false", "False": return false
        default: return nil
        }
    }

    /// Query parameters: moby's httputils.BoolValue. Trimmed and lowercased,
    /// false only for a small set of spellings — any other non-empty value is
    /// true (so `tty=1` and even `tty=yes-please` are true, exactly like dockerd).
    static func queryValue(_ value: String?) -> Bool {
        !["", "0", "no", "false", "none"].contains((value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// moby's httputils.BoolValueOrDefault: an absent parameter keeps the
    /// endpoint's default (stats' `stream` defaults to true); a present one
    /// follows BoolValue.
    static func queryValue(_ value: String?, defaultingTo defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        return queryValue(value)
    }
}
