import Vapor

struct LibpodContainerCreateRequest: Content {
    let image: String
    let command: [String]?
    let remove: Bool?
    let name: String?
}
