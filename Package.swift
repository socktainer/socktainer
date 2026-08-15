// swift-tools-version:6.2
import Foundation
import PackageDescription

let buildGitCommit = ProcessInfo.processInfo.environment["BUILD_GIT_COMMIT"] ?? "unspecified"
let buildVersion = ProcessInfo.processInfo.environment["BUILD_VERSION"] ?? "unspecified"
let buildTime = ProcessInfo.processInfo.environment["BUILD_TIME"] ?? "unspecified"
let dockerEngineApiMinVersion = ProcessInfo.processInfo.environment["DOCKER_ENGINE_API_MIN_VERSION"] ?? "v1.32"
let dockerEngineApiMaxVersion = ProcessInfo.processInfo.environment["DOCKER_ENGINE_API_MAX_VERSION"] ?? "v1.51"
let package = Package(
    name: "GlassDock",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "GlassDockControl", targets: ["GlassDockControl"]),
        .library(name: "GlassDockMenuKit", targets: ["GlassDockMenuKit"]),
        .executable(name: "glassdock", targets: ["GlassDock"]),
        .executable(name: "glassdockctl", targets: ["glassdockctl"]),
        .executable(name: "GlassDockMenu", targets: ["GlassDockMenu"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/container.git", exact: "1.2.1"),
        .package(url: "https://github.com/apple/containerization.git", exact: "0.40.1"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.3"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.11.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.1"),
        .package(url: "https://github.com/mw99/DataCompression.git", from: "3.9.0"),
        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7"),
    ],
    targets: [
        .target(
            name: "GlassDockControl"
        ),
        .executableTarget(
            name: "GlassDock",
            dependencies: [
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerNetworkClient", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerRuntimeClient", package: "container"),
                .product(name: "SocketForwarder", package: "container"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "DataCompression", package: "DataCompression"),
                .product(name: "libzstd", package: "zstd"),
                "CFilteredStream",
                "BuildInfo",
            ]
        ),
        .executableTarget(
            name: "glassdockctl",
            dependencies: [
                "GlassDockControl",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "GlassDockMenu",
            dependencies: ["GlassDockMenuKit"]
        ),
        .target(
            name: "GlassDockMenuKit",
            dependencies: ["GlassDockControl"]
        ),
        .testTarget(
            name: "GlassDockTests",
            dependencies: [
                .target(name: "GlassDock"),
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "libzstd", package: "zstd"),
            ],
        ),
        .testTarget(
            name: "GlassDockControlTests",
            dependencies: ["GlassDockControl"]
        ),
        .testTarget(
            name: "GlassDockMenuKitTests",
            dependencies: ["GlassDockMenuKit"]
        ),
        .target(
            name: "CFilteredStream",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("archive"),
                .linkedLibrary("lzma"),
            ]
        ),
        .target(
            name: "BuildInfo",
            dependencies: [],
            publicHeadersPath: "include",
            cSettings: [
                .define("BUILD_GIT_COMMIT", to: "\"\(buildGitCommit)\""),
                .define("BUILD_VERSION", to: "\"\(buildVersion)\""),
                .define("BUILD_TIME", to: "\"\(buildTime)\""),
                .define("DOCKER_ENGINE_API_MIN_VERSION", to: "\"\(dockerEngineApiMinVersion)\""),
                .define("DOCKER_ENGINE_API_MAX_VERSION", to: "\"\(dockerEngineApiMaxVersion)\""),
            ]
        ),
    ]
)
