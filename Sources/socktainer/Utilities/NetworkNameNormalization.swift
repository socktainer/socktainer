import Foundation

/// Maps Docker network names onto names Apple Container accepts.
///
/// Apple Container only allows lowercase network names
/// (`^[a-z0-9](?:[a-z0-9._-]{0,61}[a-z0-9])?$`), while Docker allows mixed case.
/// Clients such as .NET Aspire create networks like `aspire-session-network-x-MyApp.Web`,
/// so every client-supplied network name is lowercased before it reaches Apple Container.
/// The stored (lowercase) name is what socktainer reports back.
///
/// Docker network names are case-sensitive; after normalization `Foo` and `foo`
/// refer to the same network.
enum NetworkNameNormalization {
    static func normalize(_ name: String) -> String {
        name.lowercased()
    }
}
