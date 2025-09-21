import Vapor

struct ContainerState: Content {
    let Status: String
    let Running: Bool
    let Paused: Bool
    let Restarting: Bool
    let OOMKilled: Bool
    let Dead: Bool
    let Pid: Int
    let ExitCode: Int
    let Error: String
    let StartedAt: String
    let FinishedAt: String
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
    let Config: ContainerConfig
    let HostConfig: HostConfig
    let NetworkSettings: NetworkSettings
}

struct RESTContainerListQuery: Content {
    let all: Bool?
}
