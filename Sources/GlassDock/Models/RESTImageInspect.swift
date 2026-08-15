import Vapor

extension KeyedEncodingContainer {
    fileprivate mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

struct OCIDescriptor: Content {
    let mediaType: String?
    let digest: String?
    let size: Int64?
    let urls: [String]?
    let annotations: [String: String]?
    let data: String?
    let platform: OCIPlatform?
    let artifactType: String?

    struct OCIPlatform: Content {
        let architecture: String?
        let os: String?
        let osVersion: String?
        let osFeatures: [String]?
        let variant: String?

        enum CodingKeys: String, CodingKey {
            case architecture
            case os
            case osVersion
            case osFeatures
            case variant
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNullable(architecture, forKey: .architecture)
            try container.encodeNullable(os, forKey: .os)
            try container.encodeNullable(osVersion, forKey: .osVersion)
            try container.encodeNullable(osFeatures, forKey: .osFeatures)
            try container.encodeNullable(variant, forKey: .variant)
        }
    }

    enum CodingKeys: String, CodingKey {
        case mediaType
        case digest
        case size
        case urls
        case annotations
        case data
        case platform
        case artifactType
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNullable(mediaType, forKey: .mediaType)
        try container.encodeNullable(digest, forKey: .digest)
        try container.encodeNullable(size, forKey: .size)
        try container.encodeNullable(urls, forKey: .urls)
        try container.encodeNullable(annotations, forKey: .annotations)
        try container.encodeNullable(data, forKey: .data)
        try container.encodeNullable(platform, forKey: .platform)
        try container.encodeNullable(artifactType, forKey: .artifactType)
    }
}

struct ImageManifestSummary: Content {
    let ID: String?
    let Descriptor: OCIDescriptor?
    let Available: Bool?
    let Kind: String?
    let Size: ImageManifestSize?
    let ImageData: ImageManifestData?
    let AttestationData: AttestationManifestData?

    struct ImageManifestSize: Content {
        let Total: Int64?
        let Content: Int64?

        enum CodingKeys: String, CodingKey {
            case Total
            case Content
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNullable(Total, forKey: .Total)
            try container.encodeNullable(Content, forKey: .Content)
        }
    }

    struct ImageManifestData: Content {
        let Platform: OCIDescriptor.OCIPlatform?
        let Containers: [String]
        let Size: ImageManifestImageSize

        enum CodingKeys: String, CodingKey {
            case Platform
            case Containers
            case Size
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNullable(Platform, forKey: .Platform)
            try container.encode(Containers, forKey: .Containers)
            try container.encode(Size, forKey: .Size)
        }

        struct ImageManifestImageSize: Content {
            let Unpacked: Int64?

            enum CodingKeys: String, CodingKey {
                case Unpacked
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeNullable(Unpacked, forKey: .Unpacked)
            }
        }
    }

    struct AttestationManifestData: Content {
        let For: String
    }

    enum CodingKeys: String, CodingKey {
        case ID
        case Descriptor
        case Available
        case Kind
        case Size
        case ImageData
        case AttestationData
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNullable(ID, forKey: .ID)
        try container.encodeNullable(Descriptor, forKey: .Descriptor)
        try container.encodeNullable(Available, forKey: .Available)
        try container.encodeNullable(Kind, forKey: .Kind)
        try container.encodeNullable(Size, forKey: .Size)
        try container.encodeNullable(ImageData, forKey: .ImageData)
        try container.encodeNullable(AttestationData, forKey: .AttestationData)
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

    enum CodingKeys: String, CodingKey {
        case User
        case ExposedPorts
        case Env
        case Cmd
        case Healthcheck
        case ArgsEscaped
        case Volumes
        case WorkingDir
        case Entrypoint
        case OnBuild
        case Labels
        case StopSignal
        case Shell
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNullable(User, forKey: .User)
        try container.encodeNullable(ExposedPorts, forKey: .ExposedPorts)
        try container.encodeNullable(Env, forKey: .Env)
        try container.encodeNullable(Cmd, forKey: .Cmd)
        try container.encodeNullable(Healthcheck, forKey: .Healthcheck)
        try container.encodeNullable(ArgsEscaped, forKey: .ArgsEscaped)
        try container.encodeNullable(Volumes, forKey: .Volumes)
        try container.encodeNullable(WorkingDir, forKey: .WorkingDir)
        try container.encodeNullable(Entrypoint, forKey: .Entrypoint)
        try container.encodeNullable(OnBuild, forKey: .OnBuild)
        try container.encodeNullable(Labels, forKey: .Labels)
        try container.encodeNullable(StopSignal, forKey: .StopSignal)
        try container.encodeNullable(Shell, forKey: .Shell)
    }
}

struct HealthConfig: Content {
    let Test: [String]?
    let Interval: Int64?
    let Timeout: Int64?
    let Retries: Int?
    let StartPeriod: Int64?
    let StartInterval: Int64?

    enum CodingKeys: String, CodingKey {
        case Test
        case Interval
        case Timeout
        case Retries
        case StartPeriod
        case StartInterval
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNullable(Test, forKey: .Test)
        try container.encodeNullable(Interval, forKey: .Interval)
        try container.encodeNullable(Timeout, forKey: .Timeout)
        try container.encodeNullable(Retries, forKey: .Retries)
        try container.encodeNullable(StartPeriod, forKey: .StartPeriod)
        try container.encodeNullable(StartInterval, forKey: .StartInterval)
    }
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rootfsType, forKey: .rootfsType)
        try container.encodeNullable(Layers, forKey: .Layers)
    }
}

struct ImageMetadata: Content {
    let LastTagTime: String?

    enum CodingKeys: String, CodingKey {
        case LastTagTime
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNullable(LastTagTime, forKey: .LastTagTime)
    }
}

struct RESTImageInspect: Content {
    let Id: String
    let Descriptor: OCIDescriptor?
    let Manifests: [ImageManifestSummary]?
    let RepoTags: [String]
    let RepoDigests: [String]
    let Parent: String
    let Comment: String
    let Created: String?
    let DockerVersion: String
    let Author: String
    let Config: ImageConfig?
    let Architecture: String
    let Variant: String?
    let Os: String
    let OsVersion: String?
    let Size: Int64
    let GraphDriver: DriverData?
    let RootFS: RootFS?
    let Metadata: ImageMetadata?

    enum CodingKeys: String, CodingKey {
        case Id
        case Descriptor
        case Manifests
        case RepoTags
        case RepoDigests
        case Parent
        case Comment
        case Created
        case DockerVersion
        case Author
        case Config
        case Architecture
        case Variant
        case Os
        case OsVersion
        case Size
        case GraphDriver
        case RootFS
        case Metadata
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Id, forKey: .Id)
        try container.encodeNullable(Descriptor, forKey: .Descriptor)
        try container.encodeNullable(Manifests, forKey: .Manifests)
        try container.encode(RepoTags, forKey: .RepoTags)
        try container.encode(RepoDigests, forKey: .RepoDigests)
        try container.encode(Parent, forKey: .Parent)
        try container.encode(Comment, forKey: .Comment)
        try container.encodeNullable(Created, forKey: .Created)
        try container.encode(DockerVersion, forKey: .DockerVersion)
        try container.encode(Author, forKey: .Author)
        try container.encodeNullable(Config, forKey: .Config)
        try container.encode(Architecture, forKey: .Architecture)
        try container.encodeNullable(Variant, forKey: .Variant)
        try container.encode(Os, forKey: .Os)
        try container.encodeNullable(OsVersion, forKey: .OsVersion)
        try container.encode(Size, forKey: .Size)
        try container.encodeNullable(GraphDriver, forKey: .GraphDriver)
        try container.encodeNullable(RootFS, forKey: .RootFS)
        try container.encodeNullable(Metadata, forKey: .Metadata)
    }
}
