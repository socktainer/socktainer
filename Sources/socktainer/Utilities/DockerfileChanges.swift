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
        let tokens = splitRespectingQuotes(rest)
        guard !tokens.isEmpty else {
            throw DockerfileChangeError.invalidValue(instruction: "ENV", value: rest)
        }
        if tokens.count == 2, !tokens[0].contains("=") {
            config.setEnv(key: tokens[0], value: tokens[1])
            return
        }
        for token in tokens {
            guard let equalsIndex = token.firstIndex(of: "=") else {
                throw DockerfileChangeError.invalidValue(instruction: "ENV", value: token)
            }
            let key = String(token[..<equalsIndex])
            let value = String(token[token.index(after: equalsIndex)...])
            config.setEnv(key: key, value: value)
        }
    }

    /// `LABEL KEY=VALUE ...`, quoting allowed for values containing spaces.
    private static func applyLabels(_ rest: String, to config: inout SynthesizedImageConfig) throws {
        let tokens = splitRespectingQuotes(rest)
        guard !tokens.isEmpty else {
            throw DockerfileChangeError.invalidValue(instruction: "LABEL", value: rest)
        }
        for token in tokens {
            guard let equalsIndex = token.firstIndex(of: "=") else {
                throw DockerfileChangeError.invalidValue(instruction: "LABEL", value: token)
            }
            let key = String(token[..<equalsIndex])
            let value = String(token[token.index(after: equalsIndex)...])
            config.labels[key] = value
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
        return splitRespectingQuotes(rest)
    }

    /// Splits on whitespace, treating a `"..."`/`'...'` span as one token and
    /// dropping its quotes (enough for `LABEL desc="two words"`-style values;
    /// no backslash-escape support).
    private static func splitRespectingQuotes(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoteChar: Character?
        for char in value {
            if let openQuote = quoteChar {
                if char == openQuote {
                    quoteChar = nil
                } else {
                    current.append(char)
                }
            } else if char == "\"" || char == "'" {
                quoteChar = char
            } else if char == " " || char == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
