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
    let ImageManifestDescriptor: ImageOCIDescriptor?
    let Command: String
    let Created: Int64
    let Ports: [ContainerPort]
    let SizeRw: Int64?
    let SizeRootFs: Int64?
    let Labels: [String: String]
    let State: String
    let Status: String
    let HostConfig: ContainerHostConfig
    let NetworkSettings: ContainerNetworkSummary
    let Mounts: [ContainerMountPoint]
    let Platform: String
}

struct RESTContainerInspect: Content {
    let Id: String
    let Created: String?
    let Path: String
    let Args: [String]
    let State: ContainerState
    let Image: String
    let ResolvConfPath: String
    let HostnamePath: String
    let HostsPath: String
    let LogPath: String?
    let Name: String
    let RestartCount: Int
    let Driver: String
    let Platform: String
    let ImageManifestDescriptor: ImageOCIDescriptor?
    let MountLabel: String
    let ProcessLabel: String
    let AppArmorProfile: String
    let ExecIDs: [String]?
    let HostConfig: HostConfig
    let GraphDriver: ContainerDriverData
    let SizeRw: Int64?
    let SizeRootFs: Int64?
    let Mounts: [ContainerMountPoint]
    let Config: ContainerConfig
    let NetworkSettings: ContainerNetworkSettings
}

struct RESTContainerListQuery: Content {
    let all: Bool?
}
