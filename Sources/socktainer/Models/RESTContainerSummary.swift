import Vapor


struct ContainerState: Content {
    let Status: String
}

struct RESTContainerSummary: Content {
    let Id: String
    let Names: [String]
    let Image: String
    let ImageID: String
    let State: String
}


struct RESTContainerInspect: Content {
    let Id: String
    let Names: [String]
    let Image: String
    let ImageID: String
    let State: ContainerState
}

struct RESTContainerListQuery: Content {
    let all: Bool?
}
