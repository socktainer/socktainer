import Vapor

struct RESTImageSummary: Content {
    let Id: String
    let ParentId: String
    let RepoTags: [String]
    let RepoDigests: [String]
    let Created: Int
    let Size: Int64
    let SharedSize: Int64
    let Labels: [String: String]
    let Containers: Int
    let Manifests: [ImageManifestSummary]?
    let Descriptor: OCIDescriptor?

    enum CodingKeys: String, CodingKey {
        case Id
        case ParentId
        case RepoTags
        case RepoDigests
        case Created
        case Size
        case SharedSize
        case Labels
        case Containers
        case Manifests
        case Descriptor
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Id, forKey: .Id)
        try container.encode(ParentId, forKey: .ParentId)
        try container.encode(RepoTags, forKey: .RepoTags)
        try container.encode(RepoDigests, forKey: .RepoDigests)
        try container.encode(Created, forKey: .Created)
        try container.encode(Size, forKey: .Size)
        try container.encode(SharedSize, forKey: .SharedSize)
        try container.encode(Labels, forKey: .Labels)
        try container.encode(Containers, forKey: .Containers)
        if let Manifests {
            try container.encode(Manifests, forKey: .Manifests)
        } else {
            try container.encodeNil(forKey: .Manifests)
        }
        if let Descriptor {
            try container.encode(Descriptor, forKey: .Descriptor)
        } else {
            try container.encodeNil(forKey: .Descriptor)
        }
    }
}
