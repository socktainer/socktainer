import Foundation

/// Turns raw BuildKit progress output into deduplicated plain lines for the
/// Docker build JSON stream, and remembers the last error line so a failed
/// build reports the real reason instead of a bare gRPC cancellation.
///
/// ponytail: apple/container only exposes a custom output sink through
/// `terminal`, which forces BuildKit into `progress=tty` (ANSI redraws of the
/// whole screen). The ANSI stripping and timer-insensitive dedupe below are a
/// heuristic for that mode; drop them once upstream offers a plain-output sink.
struct BuildOutputCollector {
    private var pending = Data()
    private var seen = Set<String>()
    private(set) var failureReason: String?

    private static let ansi = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*\u{07}|\u{1B}[()][A-Za-z0-9]|\u{1B}[=>78]")
    private static let timer = try! NSRegularExpression(pattern: "\\s+(DONE\\s+)?\\d+(\\.\\d+)?s$")

    /// Feeds a chunk of output and returns the lines not emitted before.
    mutating func ingest(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let raw = pending[pending.startIndex..<index]
            pending.removeSubrange(pending.startIndex...index)
            if let line = accept(String(decoding: raw, as: UTF8.self)) {
                lines.append(line)
            }
        }
        return lines
    }

    /// Flushes a trailing line that was not newline-terminated.
    mutating func finish() -> [String] {
        defer { pending.removeAll() }
        return accept(String(decoding: pending, as: UTF8.self)).map { [$0] } ?? []
    }

    private mutating func accept(_ raw: String) -> String? {
        let line = Self.replace(Self.ansi, in: raw, with: "").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("[+] Building") else { return nil }
        if line.contains("ERROR:") || line.contains("did not complete successfully") {
            failureReason = line
        }
        guard seen.insert(Self.replace(Self.timer, in: line, with: "")).inserted else { return nil }
        return line
    }

    private static func replace(_ regex: NSRegularExpression, in string: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: string, range: NSRange(string.startIndex..., in: string), withTemplate: template)
    }
}
