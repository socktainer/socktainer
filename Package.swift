// swift-tools-version:6.2
import Foundation
import PackageDescription

let buildGitCommit = ProcessInfo.processInfo.environment["BUILD_GIT_COMMIT"] ?? "unspecified"
let buildVersion = ProcessInfo.processInfo.environment["BUILD_VERSION"] ?? "unspecified"
let buildTime = ProcessInfo.processInfo.environment["BUILD_TIME"] ?? "unspecified"
let dockerEngineApiMinVersion = ProcessInfo.processInfo.environment["DOCKER_ENGINE_API_MIN_VERSION"] ?? "unspecified"
let dockerEngineApiMaxVersion = ProcessInfo.processInfo.environment["DOCKER_ENGINE_API_MAX_VERSION"] ?? "unspecified"
let appleContainerVersion = "0.9.0"
let appleContainerizationVersion = "0.24.5"

let package = Package(
    name: "socktainer",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/container.git", exact: Version(stringLiteral: appleContainerVersion)),
        .package(url: "https://github.com/apple/containerization.git", exact: Version(stringLiteral: appleContainerizationVersion)),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.119.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.7.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.2"),
    ],
    targets: [
        .executableTarget(
            name: "socktainer",
            dependencies: [
                .product(name: "ContainerBuild", package: "container"),
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerNetworkService", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "BuildInfo",
            ],
        ),
        .testTarget(
            name: "socktainerTests",
            dependencies: [
                .target(name: "socktainer"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
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
                .define("APPLE_CONTAINER_VERSION", to: "\"\(appleContainerVersion)\""),
            ]
        ),

    ]

)
