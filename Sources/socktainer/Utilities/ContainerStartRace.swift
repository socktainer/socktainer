import Foundation

/// Returns true when `error` represents a benign concurrent-start race from
/// Apple Container — the container was already bootstrapped or started by
/// another concurrent request. Callers should swallow the error rather than
/// recording a synthetic exit code or propagating it to the caller.
///
/// Apple Container surfaces both conditions as `.invalidState` errors, so we
/// cannot distinguish them by error code alone. We match on `description`
/// (not `localizedDescription`) to avoid locale-dependent translations, with
/// case-insensitive comparison for future-proofing.
func isBenignStartRace(_ error: Error) -> Bool {
    let msg = String(describing: error)
    let options: String.CompareOptions = [.caseInsensitive]
    return msg.range(of: "booted", options: options) != nil
        || msg.range(of: "expected to be in created state", options: options) != nil
}
