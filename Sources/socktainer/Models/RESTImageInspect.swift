import Vapor

struct OCIDescriptor: Content {
    let mediaType: String?
    let digest: String?
    let size: Int64?
    let urls: [String]?
    let annotations: [String: String]?
    let platform: OCIPlatform?

    struct OCIPlatform: Content {
        let architecture: String?
        let os: String?
        let osVersion: String?
        let osFeatures: [String]?
        let variant: String?
    }
}

struct ImageManifestSummary: Content {
    let Descriptor: OCIDescriptor?
    let Available: Bool?
    let Kind: String?
    let Size: ImageManifestSize?

    struct ImageManifestSize: Content {
        let Total: Int64?
        let Content: Int64?
    }
}

struct ImageConfig: Content {
    let User: String?
    let ExposedPorts: [String: [String: String]]?
    let Env: [String]?
    let Cmd: [String]?
    let Healthcheck: HealthConfig?
    let ArgsEscaped: Bool?
    let Volumes: [String: [String: String]]?
    let WorkingDir: String?
    let Entrypoint: [String]?
    let OnBuild: [String]?
    let Labels: [String: String]?
    let StopSignal: String?
    let Shell: [String]?
}

struct HealthConfig: Content {
    let Test: [String]?
    let Interval: Int64?
    let Timeout: Int64?
    let Retries: Int?
    let StartPeriod: Int64?
    let StartInterval: Int64?
}

struct DriverData: Content {
    let Name: String
    let Data: [String: String]
}

struct RootFS: Content {
    // Using custom CodingKeys to map Swift property name to JSON key
    enum CodingKeys: String, CodingKey {
        case rootfsType = "Type"
        case Layers
    }

    let rootfsType: String
    let Layers: [String]?
}

struct ImageMetadata: Content {
    let LastTagTime: String?
}

struct RESTImageInspect: Content {
    let Id: String
    let Descriptor: OCIDescriptor?
    let Manifests: [ImageManifestSummary]?
    let RepoTags: [String]
    let RepoDigests: [String]
    let Parent: String?
    let Comment: String?
    let Created: String?
    let DockerVersion: String?
    let Author: String?
    let Config: ImageConfig?
    let Architecture: String?
    let Variant: String?
    let Os: String?
    let OsVersion: String?
    let Size: Int64
    let VirtualSize: Int64?
    let GraphDriver: DriverData?
    let RootFS: RootFS?
    let Metadata: ImageMetadata?
}
