import Vapor

struct RESTContainerCreate: Content {
    let Id: String
    let Warnings: [String]
}
