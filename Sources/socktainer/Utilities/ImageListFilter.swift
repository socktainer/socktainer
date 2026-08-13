import Foundation

/// Applies moby's `reference` and `dangling` filters to image summaries for
/// GET /images/json. Multiple values of one key are ORed; different keys AND.
/// Other image-ls keys (label/since/before/until) are not yet honored.
enum ImageListFilter {
    /// A summary is "dangling" when it carries no repository tags (moby shows
    /// such an image as `<none>:<none>`).
    static func isDangling(repoTags: [String]) -> Bool {
        repoTags.isEmpty || repoTags == ["<none>:<none>"]
    }

    /// moby matches `reference=<pattern>` with `reference.FamiliarMatch`, which
    /// runs `path.Match(pattern, x)` for exactly two forms of each repo tag: the
    /// familiar string (`alpine:latest`) and the familiar name with no tag or
    /// digest (`alpine`). The registry/library prefix docker hides is stripped
    /// for both. So `alpine`, `alpine:latest`, and `alpine:*` match a
    /// `docker.io/library/alpine:latest` image, but the fully-qualified
    /// `docker.io/library/alpine` does not (matching moby). Patterns OR together.
    static func referenceMatches(patterns: [String], repoTags: [String]) -> Bool {
        patterns.contains { pattern in
            repoTags.contains { tag in
                familiarForms(tag).contains { globMatch(pattern: pattern, candidate: $0) }
            }
        }
    }

    /// The two forms moby matches a reference against: the familiar string and
    /// the familiar name (no tag, no digest).
    static func familiarForms(_ reference: String) -> [String] {
        let familiarString = familiarize(reference)
        // Familiar name: drop the digest first, then the tag.
        var name = familiarString
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        if let colon = name.lastIndex(of: ":"), !name[name.index(after: colon)...].contains("/") {
            name = String(name[..<colon])
        }
        return name == familiarString ? [familiarString] : [familiarString, name]
    }

    /// Strips the default registry/namespace docker hides in familiar output:
    /// `docker.io/library/alpine:latest` -> `alpine:latest`,
    /// `docker.io/user/app:1` -> `user/app:1`. Other registries are unchanged.
    private static func familiarize(_ reference: String) -> String {
        for prefix in ["docker.io/library/", "docker.io/"] where reference.hasPrefix(prefix) {
            return String(reference.dropFirst(prefix.count))
        }
        return reference
    }

    /// Go's `path.Match` semantics: `*` and `?` never match the path separator
    /// `/`, so match segment by segment with an equal segment count.
    static func globMatch(pattern: String, candidate: String) -> Bool {
        let pSegs = pattern.split(separator: "/", omittingEmptySubsequences: false)
        let cSegs = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard pSegs.count == cSegs.count else { return false }
        return zip(pSegs, cSegs).allSatisfy { wildcard(Array($0), Array($1)) }
    }

    /// `*`/`?` wildcard match within a single path segment (no `/`).
    private static func wildcard(_ p: [Character], _ s: [Character]) -> Bool {
        var pi = 0
        var si = 0
        var star = -1
        var mark = 0
        while si < s.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == s[si]) {
                pi += 1
                si += 1
            } else if pi < p.count && p[pi] == "*" {
                star = pi
                mark = si
                pi += 1
            } else if star != -1 {
                pi = star + 1
                mark += 1
                si = mark
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
