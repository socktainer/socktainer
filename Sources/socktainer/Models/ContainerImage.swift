struct TarManifest: Codable {
    let config: String?
    let repoTags: [String]?
    let layers: [String]?

    enum CodingKeys: String, CodingKey {
        case config = "Config"
        case repoTags = "RepoTags"
        case layers = "Layers"
    }
}

struct OCILayoutIndex: Codable {
    let schemaVersion: Int
    let manifests: [OCILayoutDescriptor]
}

struct OCILayoutDescriptor: Codable {
    let mediaType: String
    let digest: String
    let size: Int
}

struct OCILayoutManifest: Codable {
    let schemaVersion: Int
    let config: OCILayoutDescriptor
    let layers: [OCILayoutDescriptor]
}
