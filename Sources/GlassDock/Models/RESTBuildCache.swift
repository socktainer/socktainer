import Vapor

struct RESTBuildCache: Content {
    let ID: String
    let Parents: [String]?
    let kind: String
    let Description: String
    let InUse: Bool
    let Shared: Bool
    let Size: Int64
    let CreatedAt: String
    let LastUsedAt: String?
    let UsageCount: Int

    enum CodingKeys: String, CodingKey {
        case ID
        case Parents
        case kind = "Type"
        case Description
        case InUse
        case Shared
        case Size
        case CreatedAt
        case LastUsedAt
        case UsageCount
    }
}
