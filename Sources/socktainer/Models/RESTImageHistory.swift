import Vapor

struct RESTImageHistoryResponseItem: Content {
    let Id: String
    let Created: Int64
    let CreatedBy: String
    let Tags: [String]
    let Size: Int64
    let Comment: String
}
