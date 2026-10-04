import Foundation

/// Name filters come from clients. Compile once per list request and use ICU's
/// progress callback to stop pathological backtracking rather than letting one
/// expression monopolize the daemon. Invalid or exhausted patterns do not match.
struct DockerContainerNameMatcher {
    private let expressions: [NSRegularExpression]
    static let maximumPatternBytes = 4096
    static let matchingBudget: Duration = .milliseconds(10)

    init(patterns: [String]) {
        expressions = patterns.compactMap { pattern in
            guard pattern.utf8.count <= Self.maximumPatternBytes else { return nil }
            return try? NSRegularExpression(pattern: pattern)
        }
    }

    func matches(_ name: String) -> Bool {
        expressions.contains { expression in
            matches(expression, name: name) || matches(expression, name: "/" + name)
        }
    }

    private func matches(_ expression: NSRegularExpression, name: String) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: Self.matchingBudget)
        var found = false
        expression.enumerateMatches(in: name, options: .reportProgress, range: NSRange(name.startIndex..., in: name)) { result, flags, stop in
            if result != nil {
                found = true
                stop.pointee = true
            } else if flags.contains(.progress), ContinuousClock.now >= deadline {
                stop.pointee = true
            }
        }
        return found
    }
}
