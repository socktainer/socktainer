import ContainerPersistence
import Foundation

enum RegistryUtility {
    static func normalizeImageReference(_ reference: String) -> String {
        guard !reference.isEmpty else { return reference }

        let components = reference.split(separator: "/", maxSplits: 1)
        if components.count > 1 {
            let firstComponent = String(components[0])
            if firstComponent.contains(".") || firstComponent.contains(":") || firstComponent == "localhost" {
                return reference
            }
        }

        // Get default registry from Apple container's DefaultsStore
        let defaultRegistry = DefaultsStore.get(key: .defaultRegistryDomain)
        let defaultRepo = "library"

        if components.count == 1 {
            return "\(defaultRegistry)/\(defaultRepo)/\(reference)"
        }

        // For multi-component references without domain, just add the registry
        return "\(defaultRegistry)/\(reference)"
    }
}
