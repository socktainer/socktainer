import Vapor

// NOTE: Doesn't attempt to mimic fully the schema
//       https://docs.docker.com/reference/api/engine/version/v1.51/#tag/System/operation/SystemAuth
//       Things that should be revisited in the future
//       - Driver + Driver Status (storage)
//       - Plugins
//       - Registry config
//       - Init binary + commit
//       - Default network address pool
struct SystemInfo: Content {
    var Containers: Int
    var ContainersRunning: Int
    /// NOTE: Apple container doesn't support pausing containers
    var ContainersPaused: Int
    var ContainersStopped: Int
    var Images: Int
    var DockerRootDir: String
    var Debug: Bool
    var KernelVersion: String
    var OSVersion: String?
    var OSType: String
    var Architecture: String
    var NCPU: Int
    var MemTotal: Int64
    var HttpProxy: String?
    var HttpsProxy: String?
    var NoProxy: String?
    var Name: String
    // NOTE: Consider enabling user to define labels
    var Labels: [String]?
    var ExperimentalBuild: Bool
    var ServerVersion: String
    var Runtimes: [String: Runtime]
    var DefaultRuntime: String
    var ProductLicense: String
    var SystemTime: String
    var Warnings: [String]
}

struct Runtime: Content {
    var path: String
}

// NOTE: Doesn't attempt to mimic fully the schema
// https://docs.docker.com/reference/api/engine/version/v1.51/#tag/System/operation/SystemVersion
struct VersionInfo: Content {
    var Platform: ServerPlatform
    var Components: [Component]
    var Version: String
    var ApiVersion: String
    var MinAPIVersion: String
    var GitCommit: String
    var Os: String
    var Arch: String
    var KernelVersion: String
    var Experimental: Bool
    var BuildTime: String

}

struct ServerPlatform: Content {
    var Name: String
}

struct Component: Content {
    var Name: String
    var Version: String
}
