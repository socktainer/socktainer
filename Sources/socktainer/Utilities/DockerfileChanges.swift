import Foundation

/// Errors raised while applying `docker import --change` (Dockerfile-instruction-like)
/// directives to a synthesized image config.
enum DockerfileChangeError: Error, LocalizedError {
    case invalidInstruction(String)
    case invalidValue(instruction: String, value: String)

    var errorDescription: String? {
        switch self {
        case .invalidInstruction(let instruction):
            return "\(instruction) is not a supported --change instruction"
        case .invalidValue(let instruction, let value):
            return "invalid value for \(instruction): \(value)"
        }
    }
}

/// Accumulates the subset of `container_config`/OCI image config fields that
/// `docker import --change` can set. Serialized by `ContainerImageUtility` as the
/// image config's `config` object, matching Docker's PascalCase field names —
/// including `ExposedPorts`/`Volumes`, which `ContainerizationOCI.ImageConfig`
/// does not model but which `ImageStore.load` decodes past without error (extra
/// JSON keys are simply ignored), so they still round-trip through the store.
struct SynthesizedImageConfig {
    var user: String?
    var exposedPorts: Set<String> = []
    var env: [String] = []
    var entrypoint: [String]?
    var cmd: [String]?
    var volumes: Set<String> = []
    var workingDir: String?
    var labels: [String: String] = [:]

    mutating func setEnv(key: String, value: String) {
        let prefix = "\(key)="
        if let index = env.firstIndex(where: { $0.hasPrefix(prefix) }) {
            env[index] = "\(key)=\(value)"
        } else {
            env.append("\(key)=\(value)")
        }
    }

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [:]
        if let user, !user.isEmpty { dict["User"] = user }
        if !exposedPorts.isEmpty { dict["ExposedPorts"] = emptyObjectMap(for: exposedPorts) }
        if !env.isEmpty { dict["Env"] = env }
        if let entrypoint { dict["Entrypoint"] = entrypoint }
        if let cmd { dict["Cmd"] = cmd }
        if !volumes.isEmpty { dict["Volumes"] = emptyObjectMap(for: volumes) }
        if let workingDir, !workingDir.isEmpty { dict["WorkingDir"] = workingDir }
        if !labels.isEmpty { dict["Labels"] = labels }
        return dict
    }

    private func emptyObjectMap(for keys: Set<String>) -> [String: [String: String]] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, [:]) })
    }
}

/// Applies `docker import --change` directives (one Dockerfile instruction per
/// entry) to a `SynthesizedImageConfig`. Supports the instructions the
/// import route offers: CMD, ENTRYPOINT, ENV, EXPOSE, LABEL, USER, VOLUME, WORKDIR.
/// Anything else (ONBUILD, STOPSIGNAL, HEALTHCHECK, or a genuinely unknown
/// instruction) is rejected rather than silently dropped.
enum DockerfileChangeApplier {
    static func apply(_ changes: [String], to config: inout SynthesizedImageConfig) throws {
        for change in changes {
            try applyOne(change, to: &config)
        }
    }

    private static func applyOne(_ change: String, to config: inout SynthesizedImageConfig) throws {
        let trimmed = change.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let separatorIndex = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            throw DockerfileChangeError.invalidInstruction(trimmed)
        }
        let instruction = trimmed[..<separatorIndex].uppercased()
        let rest = trimmed[trimmed.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else {
            throw DockerfileChangeError.invalidValue(instruction: instruction, value: "")
        }

        switch instruction {
        case "CMD": config.cmd = try parseExecOrShellForm(instruction: instruction, rest)
        case "ENTRYPOINT": config.entrypoint = try parseExecOrShellForm(instruction: instruction, rest)
        case "ENV": try applyEnv(rest, to: &config)
        case "LABEL": try applyLabels(rest, to: &config)
        case "USER": config.user = rest
        case "WORKDIR": config.workingDir = rest
        case "EXPOSE": config.exposedPorts.formUnion(parsePorts(rest))
        case "VOLUME": config.volumes.formUnion(try parseVolumes(instruction: instruction, rest))
        default:
            throw DockerfileChangeError.invalidInstruction(instruction)
        }
    }

    /// CMD/ENTRYPOINT accept either JSON exec form (`["a", "b"]`) or shell form,
    /// which Docker wraps as `["/bin/sh", "-c", <rest>]`.
    private static func parseExecOrShellForm(instruction: String, _ rest: String) throws -> [String] {
        if rest.hasPrefix("[") {
            guard let data = rest.data(using: .utf8),
                let array = try? JSONDecoder().decode([String].self, from: data)
            else {
                throw DockerfileChangeError.invalidValue(instruction: instruction, value: rest)
            }
            return array
        }
        return ["/bin/sh", "-c", rest]
    }

    /// `ENV KEY=VALUE ...` (one or more pairs) or the legacy `ENV KEY VALUE` form.
    private static func applyEnv(_ rest: String, to config: inout SynthesizedImageConfig) throws {
        try applyKeyValuePairs(rest, instruction: "ENV") { key, value in
            config.setEnv(key: key, value: value)
        }
    }

    /// `LABEL KEY=VALUE ...`, quoting allowed for values containing spaces.
    private static func applyLabels(_ rest: String, to config: inout SynthesizedImageConfig) throws {
        try applyKeyValuePairs(rest, instruction: "LABEL") { key, value in
            config.labels[key] = value
        }
    }

    /// Shared `ENV`/`LABEL` grammar: one or more `KEY=VALUE` pairs (quoting and
    /// backslash-escaping honored per pair), or the legacy `KEY VALUE` form —
    /// used only when the first word has no `=`, in which case the ENTIRE
    /// remainder of the line (internal whitespace preserved, not re-split into
    /// further words) becomes the single value. Verified against real
    /// `docker build` (BuildKit) output: `ENV FOO bar=1 baz=2` sets one
    /// variable `FOO="bar=1 baz=2"`, and `ENV NAME   spaced   out` preserves
    /// the internal run of spaces — both are legacy form, decided solely by
    /// whether the first word contains `=`.
    private static func applyKeyValuePairs(_ rest: String, instruction: String, set: (String, String) -> Void) throws {
        let (firstRaw, remainder) = splitFirstToken(Substring(rest))
        let firstKey = dequote(firstRaw)
        if !firstKey.contains("="), let remainder {
            set(firstKey, dequote(remainder))
            return
        }
        guard firstKey.contains("=") else {
            throw DockerfileChangeError.invalidValue(instruction: instruction, value: rest)
        }
        for token in tokenize(rest) {
            // A blank name is only rejected in this `KEY=VALUE` form — real
            // docker build accepts a blank name from the legacy branch above
            // (`ENV "" value` sets "" to "value"); the two forms are not
            // symmetric, verified against real `docker build` output.
            guard let equalsIndex = token.firstIndex(of: "="), equalsIndex > token.startIndex else {
                throw DockerfileChangeError.invalidValue(instruction: instruction, value: token)
            }
            let key = String(token[..<equalsIndex])
            let value = String(token[token.index(after: equalsIndex)...])
            set(key, value)
        }
    }

    /// `EXPOSE <port>[/<proto>] ...`, defaulting to `/tcp`.
    private static func parsePorts(_ rest: String) -> [String] {
        rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { token in
            token.contains("/") ? String(token) : "\(token)/tcp"
        }
    }

    /// `VOLUME ["/data", ...]` (JSON form) or `VOLUME /data /data2` (shell form).
    private static func parseVolumes(instruction: String, _ rest: String) throws -> [String] {
        if rest.hasPrefix("[") {
            guard let data = rest.data(using: .utf8),
                let array = try? JSONDecoder().decode([String].self, from: data)
            else {
                throw DockerfileChangeError.invalidValue(instruction: instruction, value: rest)
            }
            return array
        }
        return tokenize(rest)
    }

    /// Splits `value` on unquoted, unescaped whitespace into raw (not yet
    /// dequoted) tokens.
    private static func tokenize(_ value: String) -> [String] {
        var tokens: [String] = []
        var remainder: Substring? = Substring(value)
        while let current = remainder, !current.isEmpty {
            let (rawToken, rest) = splitFirstToken(current)
            if !rawToken.isEmpty { tokens.append(dequote(rawToken)) }
            remainder = rest
        }
        return tokens
    }

    /// Splits off the first whitespace-delimited raw token, honoring
    /// `"..."`/`'...'` quoting and backslash-escaping so an escaped or quoted
    /// space doesn't end the token early. Returns the raw (not yet dequoted)
    /// token and everything after the whitespace that follows it — `nil` if
    /// nothing follows.
    private static func splitFirstToken(_ value: Substring) -> (first: Substring, remainder: Substring?) {
        var start = value.startIndex
        while start < value.endIndex, value[start] == " " || value[start] == "\t" {
            start = value.index(after: start)
        }
        var index = start
        var escaped = false
        var quote: Character?
        while index < value.endIndex {
            let char = value[index]
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if let openQuote = quote {
                if char == openQuote { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == " " || char == "\t" {
                break
            }
            index = value.index(after: index)
        }
        let first = value[start..<index]
        guard index < value.endIndex else { return (first, nil) }
        var remainderStart = index
        while remainderStart < value.endIndex, value[remainderStart] == " " || value[remainderStart] == "\t" {
            remainderStart = value.index(after: remainderStart)
        }
        return (first, remainderStart < value.endIndex ? value[remainderStart...] : "")
    }

    /// Removes backslash-escapes (`\X` -> literal `X`) and strips a matching
    /// pair of enclosing `"`/`'` quote characters, honoring escapes even
    /// inside a quoted span (`"a\"b"` -> `a"b"`). Whitespace outside of an
    /// escape or quote is preserved literally — this is applied to the WHOLE
    /// remainder for the legacy `KEY VALUE` form, not per-word, which is why
    /// internal spacing in the value survives untouched.
    private static func dequote<S: StringProtocol>(_ value: S) -> String {
        var result = ""
        var escaped = false
        var quote: Character?
        for char in value {
            if escaped {
                result.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if let openQuote = quote {
                if char == openQuote {
                    quote = nil
                } else {
                    result.append(char)
                }
            } else if char == "\"" || char == "'" {
                quote = char
            } else {
                result.append(char)
            }
        }
        return result
    }
}
