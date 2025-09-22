import Vapor

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
    let Image: String
    let ExposedPorts: [String: EmptyObject]?

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
