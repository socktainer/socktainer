import ContainerResource
import Foundation

/// Maps Docker network names onto names Apple Container accepts.
///
/// Apple Container only allows short lowercase network names
/// (`^[a-z0-9](?:[a-z0-9._-]{0,61}[a-z0-9])?$`), while Docker allows mixed case and longer
/// names. Clients such as .NET Aspire create networks like `aspire-session-network-x-MyApp.Web`,
/// so every client-supplied network name is normalized before it reaches Apple Container.
///
/// When the stored name differs, the network records the client's name in
/// `originalNameLabel` and reports it as `Name`; `Id` stays the stored name. Containers
/// record the display names of their networks in `containerNetworkNamesLabel`.
///
/// Docker network names are case-sensitive; after normalization `Foo` and `foo`
/// refer to the same network.
enum NetworkNameNormalization {
    /// Network label holding the client's exact name when the stored name differs.
    static let originalNameLabel = "socktainer.network-original-name"
    /// Container label holding a JSON `{stored: display}` map of attached network names
    /// whose display name differs from the stored name.
    static let containerNetworkNamesLabel = "socktainer.network-names"

    static let maxLength = 63
    private static let hashLength = 12

    /// Lowercases `name`. If the result is still not a valid Apple Container network name
    /// (too long, characters outside `[a-z0-9._-]`, or a leading/trailing separator), it is
    /// replaced by a sanitized prefix plus a hash of the lowercased name, so the mapping is
    /// deterministic, case-insensitive, and idempotent (a valid output maps to itself).
    static func normalize(_ name: String) -> String {
        let lowercased = name.lowercased()
        if NetworkResource.nameValid(lowercased) { return lowercased }

        let hash = ContainerNameUtility.hashSuffix(lowercased, length: hashLength)
        let replaced = String(
            String.UnicodeScalarView(lowercased.unicodeScalars.map { isAllowed($0) ? $0 : "-" }))
        var prefix = Substring(trimmingSeparators(Substring(replaced)))
        prefix = prefix.prefix(maxLength - hashLength - 1)
        prefix = trimmingSeparators(prefix)
        return prefix.isEmpty ? hash : "\(prefix)-\(hash)"
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        isAlphanumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    private static func trimmingSeparators(_ value: Substring) -> Substring {
        let scalars = value.unicodeScalars
        guard let start = scalars.firstIndex(where: isAlphanumeric),
            let end = scalars.lastIndex(where: isAlphanumeric)
        else { return "" }
        return Substring(scalars[start...end])
    }

    /// The name to report for a network: the original client name when recorded, else the stored name.
    static func displayName(storedName: String, networkLabels: [String: String]) -> String {
        networkLabels[originalNameLabel] ?? storedName
    }

    /// Builds the `containerNetworkNamesLabel` value for a new container.
    ///
    /// - Parameters:
    ///   - requestedNames: the raw network names from the request (EndpointsConfig keys,
    ///     legacy Networks keys, or NetworkMode).
    ///   - storedNames: the attachment network names actually used.
    ///   - originalName: looks up a stored network's recorded original name.
    /// - Returns: the JSON map, or nil when every display name equals its stored name.
    static func containerNetworkNamesLabelValue(
        requestedNames: [String],
        storedNames: [String],
        originalName: (String) async -> String?
    ) async -> String? {
        var displayByStored: [String: String] = [:]
        for stored in Set(storedNames) {
            let requested = requestedNames.first { normalize($0) == stored }
            let display = await originalName(stored) ?? requested ?? stored
            if display != stored { displayByStored[stored] = display }
        }
        guard !displayByStored.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(displayByStored) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes the `containerNetworkNamesLabel` map; empty when absent or malformed.
    static func displayNames(containerLabels: [String: String]) -> [String: String] {
        guard let json = containerLabels[containerNetworkNamesLabel],
            let map = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        else { return [:] }
        return map
    }

    /// The display name for a stored attachment network on a container.
    static func displayName(storedName: String, containerLabels: [String: String]) -> String {
        displayNames(containerLabels: containerLabels)[storedName] ?? storedName
    }

    /// Re-keys a stored-name → value dictionary by display name.
    static func displayKeyed<Value>(_ byStoredName: [String: Value], containerLabels: [String: String]) -> [String: Value] {
        let names = displayNames(containerLabels: containerLabels)
        guard !names.isEmpty else { return byStoredName }
        return Dictionary(
            byStoredName.map { (names[$0.key] ?? $0.key, $0.value) },
            uniquingKeysWith: { first, _ in first })
    }
}
