import Vapor

struct RESTImageInspect: Content {
    let Id: String
    let RepoTags: [String]
    let RepoDigests: [String]
    let Created: String
    let Size: Int64
}
