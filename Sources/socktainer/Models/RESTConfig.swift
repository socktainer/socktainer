import Vapor

// TODO: Sort out this file into logical sections

struct EmptyObject: Content {
    // Empty struct to represent {} in JSON
}

struct HealthcheckConfig: Content {
    let Test: [String]?
    let Interval: Int?
    let Timeout: Int?
    let Retries: Int?
    let StartPeriod: Int?
}

struct HostConfig: Content {
    let Binds: [String]?
    let BlkioWeight: Int?
    let BlkioWeightDevice: [BlkioWeightDevice]?
    let BlkioDeviceReadBps: [BlkioDeviceRate]?
    let BlkioDeviceWriteBps: [BlkioDeviceRate]?
    let BlkioDeviceReadIOps: [BlkioDeviceRate]?
    let BlkioDeviceWriteIOps: [BlkioDeviceRate]?
    let MemorySwappiness: Int?
    let NanoCpus: Int?
    let CapAdd: [String]?
    let CapDrop: [String]?
    let ContainerIDFile: String?
    let CpuPeriod: Int?
    let CpuRealtimePeriod: Int?
    let CpuRealtimeRuntime: Int?
    let CpuShares: Int?
    let CpuQuota: Int?
    let CpusetCpus: String?
    let CpusetMems: String?
    let Devices: [Device]?
    let DeviceCgroupRules: [String]?
    let DeviceRequests: [DeviceRequest]?
    let DiskQuota: Int?
    let Dns: [String]?
    let DnsOptions: [String]?
    let DnsSearch: [String]?
    let ExtraHosts: [String]?
    let GroupAdd: [String]?
    let IpcMode: String?
    let Cgroup: String?
    let Links: [String]?
    let LogConfig: LogConfig?
    let LxcConf: [String]?
    let Memory: Int?
    let MemorySwap: Int?
    let MemoryReservation: Int?
    let KernelMemory: Int?
    let NetworkMode: String?
    let OomKillDisable: Bool?
    let Init: Bool?
    let AutoRemove: Bool?
    let OomScoreAdj: Int?
    let PortBindings: [String: [PortBinding]]?
    let Privileged: Bool?
    let PublishAllPorts: Bool?
    let ReadonlyRootfs: Bool?
    let RestartPolicy: RestartPolicy?
    let Ulimits: [Ulimit]?
    let CpuCount: Int?
    let CpuPercent: Int?
    let IOMaximumIOps: Int?
    let IOMaximumBandwidth: Int?
    let VolumesFrom: [String]?
    let Mounts: [Mount]?
    let PidMode: String?
    let Isolation: String?
    let SecurityOpt: [String]?
    let StorageOpt: [String]?
    let CgroupParent: String?
    let VolumeDriver: String?
    let ShmSize: Int?
    let PidsLimit: Int?
    let Runtime: String?
    let Tmpfs: [String: String]?
    let UTSMode: String?
    let UsernsMode: String?
    let Sysctls: [String: String]?
    let ConsoleSize: [Int]?
    let CgroupnsMode: String?

    public init() {
        self.Binds = nil
        self.BlkioWeight = nil
        self.BlkioWeightDevice = nil
        self.BlkioDeviceReadBps = nil
        self.BlkioDeviceWriteBps = nil
        self.BlkioDeviceReadIOps = nil
        self.BlkioDeviceWriteIOps = nil
        self.MemorySwappiness = nil
        self.NanoCpus = nil
        self.CapAdd = nil
        self.CapDrop = nil
        self.ContainerIDFile = nil
        self.CpuPeriod = nil
        self.CpuRealtimePeriod = nil
        self.CpuRealtimeRuntime = nil
        self.CpuShares = nil
        self.CpuQuota = nil
        self.CpusetCpus = nil
        self.CpusetMems = nil
        self.Devices = nil
        self.DeviceCgroupRules = nil
        self.DeviceRequests = nil
        self.DiskQuota = nil
        self.Dns = nil
        self.DnsOptions = nil
        self.DnsSearch = nil
        self.ExtraHosts = nil
        self.GroupAdd = nil
        self.IpcMode = nil
        self.Cgroup = nil
        self.Links = nil
        self.LogConfig = nil
        self.LxcConf = nil
        self.Memory = nil
        self.MemorySwap = nil
        self.MemoryReservation = nil
        self.KernelMemory = nil
        self.NetworkMode = nil
        self.OomKillDisable = nil
        self.Init = nil
        self.AutoRemove = nil
        self.OomScoreAdj = nil
        self.PortBindings = nil
        self.Privileged = nil
        self.PublishAllPorts = nil
        self.ReadonlyRootfs = nil
        self.RestartPolicy = nil
        self.Ulimits = nil
        self.CpuCount = nil
        self.CpuPercent = nil
        self.IOMaximumIOps = nil
        self.IOMaximumBandwidth = nil
        self.VolumesFrom = nil
        self.Mounts = nil
        self.PidMode = nil
        self.Isolation = nil
        self.SecurityOpt = nil
        self.StorageOpt = nil
        self.CgroupParent = nil
        self.VolumeDriver = nil
        self.ShmSize = nil
        self.PidsLimit = nil
        self.Runtime = nil
        self.Tmpfs = nil
        self.UTSMode = nil
        self.UsernsMode = nil
        self.Sysctls = nil
        self.ConsoleSize = nil
        self.CgroupnsMode = nil
    }
}

struct BlkioWeightDevice: Content {
    let Path: String
    let Weight: Int
}

struct BlkioDeviceRate: Content {
    let Path: String
    let Rate: Int
}

struct Device: Content {
    let PathOnHost: String
    let PathInContainer: String
    let CgroupPermissions: String
}

struct DeviceRequest: Content {
    let Driver: String?
    let Count: Int?
    let DeviceIDs: [String]?
    let Capabilities: [[String]]?
    let Options: [String: String]?
}

struct LogConfig: Content {
    let `Type`: String
    let Config: [String: String]?
}

struct PortBinding: Content {
    let HostIp: String?
    let HostPort: String?
}

struct RestartPolicy: Content {
    let Name: String
    let MaximumRetryCount: Int?
}

struct Ulimit: Content {
    let Name: String
    let Soft: Int
    let Hard: Int
}

struct Mount: Content {
    let Target: String
    let Source: String
    let MountType: String
    let ReadOnly: Bool?
    let Consistency: String?
    let BindOptions: BindOptions?
    let VolumeOptions: VolumeOptions?
    let TmpfsOptions: TmpfsOptions?
}

struct BindOptions: Content {
    let Propagation: String?
}

struct VolumeOptions: Content {
    let NoCopy: Bool?
    let Labels: [String: String]?
    let DriverConfig: VolumeDriverConfig?
}

struct VolumeDriverConfig: Content {
    let Name: String?
    let Options: [String: String]?
}

struct TmpfsOptions: Content {
    let SizeBytes: Int?
    let Mode: Int?
}

struct ContainerNetworkSettings: Content {
    let Bridge: String?
    let SandboxID: String?
    let Ports: [String: [PortBinding]]?
    let SandboxKey: String?
    let Networks: [String: ContainerEndpointSettings]?
    let EndpointsConfig: [String: ContainerEndpointSettings]?
}

/// Address type for SecondaryIPAddresses and SecondaryIPv6Addresses
struct Address: Content {
    let Addr: String?
    let PrefixLen: Int?
}

struct ContainerEndpointSettings: Content {
    let IPAMConfig: ContainerIPAMConfig?
    let Links: [String]?
    let Aliases: [String]?
    let NetworkID: String?
    let EndpointID: String?
    let Gateway: String?
    let IPAddress: String?
    let IPPrefixLen: Int?
    let IPv6Gateway: String?
    let GlobalIPv6Address: String?
    let GlobalIPv6PrefixLen: Int?
    let MacAddress: String?
    let DriverOpts: [String: String]?
}

struct ContainerIPAMConfig: Content {
    let IPv4Address: String?
    let IPv6Address: String?
    let LinkLocalIPs: [String]?
}

struct ContainerConfig: Content {
    let Hostname: String?
    let Domainname: String?
    let User: String?
    let AttachStdin: Bool?
    let AttachStdout: Bool?
    let AttachStderr: Bool?
    let ExposedPorts: [String: EmptyObject]?
    let Tty: Bool?
    let OpenStdin: Bool?
    let StdinOnce: Bool?
    let Env: [String]?
    let Cmd: [String]?
    let Healthcheck: HealthcheckConfig?
    let ArgsEscaped: Bool?
    let Image: String
    let Volumes: [String: EmptyObject]?
    let WorkingDir: String?
    let Entrypoint: [String]?
    let NetworkDisabled: Bool?
    let MacAddress: String?
    let OnBuild: [String]?
    let Labels: [String: String]?
    let StopSignal: String?
    let StopTimeout: Int?
    let Shell: [String]?
}

// `/networks` related
public struct NetworkConfigReference: Codable, Sendable {
    public let Network: String
}

public struct NetworkContainer: Codable, Sendable {
    public let Name: String
    public let EndpointID: String?
    public let MacAddress: String?
    public let IPv4Address: String
    public let IPv6Address: String?
}

public struct NetworkLabel: Codable {
    public let Name: String
}

public struct NetworkIPAMConfig: Codable, Sendable {
    public let Subnet: String?
    public let IPRange: String?
    public let Gateway: String?
    public let AuxiliaryAddresses: [String: String]?
}

public struct NetworkIPAM: Codable, Sendable {
    public let Driver: String
    public let Config: [NetworkIPAMConfig]
}

// `/volumes` related

struct VolumeRequest: Content {
    let Name: String?
    let Driver: String?
    let DriverOpts: [String: String]?
    let Labels: [String: String]?
    let ClusterVolumeSpec: EmptyObject?
}

struct VolumeUsageData: Content {
    let Size: Int64
    let RefCount: Int64
    init() {
        self.Size = -1  // will return -1, we have no option to calculate the actual usage of volume
        self.RefCount = -1  // will return -1, we don't map attached containers to volumes
    }
}

struct Volume: Content {
    let Name: String
    let Driver: String
    let Mountpoint: String
    let CreatedAt: String?
    let Status: [String: String]?
    let Labels: [String: String]?
    let Scope: String
    let ClusterVolume: EmptyObject?  // unused, only part of swarm
    let Options: [String: String]
    let UsageData: VolumeUsageData?
}

struct VolumeInfo: Content {
    let CreatedAt: String
    let Driver: String
    let Labels: [String: String]?
    let Mountpoint: String
    let Name: String
    let Options: [String: String]
    let Scope: String
    let Status: [String: String]?  // we do not report any status from the underlying driver at the moment
    let UsageData: VolumeUsageData?
}

// image related

struct ImageOCIDescriptor: Content {
    let mediaType: String
    let digest: String
    let size: Int64
    let urls: [String]?
    let annotations: [String: String]?
    let platform: ImageOCIPlatform?
}

struct ImageOCIPlatform: Content {
    let architecture: String
    let os: String
    let osVersion: String?
    let osFeatures: [String]?
    let variant: String?
}

// container related

struct ContainerDriverData: Content {
    let Name: String
    let Data: [String: String]
}

struct ContainerMountPoint: Content {
    let type: String
    let name: String?
    let source: String
    let destination: String
    let driver: String?
    let mode: String
    let rw: Bool
    let propagation: String

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case name = "Name"
        case source = "Source"
        case destination = "Destination"
        case driver = "Driver"
        case mode = "Mode"
        case rw = "RW"
        case propagation = "Propagation"
    }
}

struct ContainerPort: Content {
    let IP: String?
    let PrivatePort: Int
    let PublicPort: Int?
    let type: String

    enum CodingKeys: String, CodingKey {
        case IP
        case PrivatePort
        case PublicPort
        case type = "Type"
    }
}

struct ContainerHostConfig: Content {
    let NetworkMode: String
    let Annotations: [String: String]?
}

struct ContainerNetworkSummary: Content {
    let Networks: [String: ContainerEndpointSettings]?
}
