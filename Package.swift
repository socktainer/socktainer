// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "socktainer",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/container.git", from: "0.4.1"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.116.0"),
 .package(url: "https://github.com/apple/swift-nio.git", from: "2.86.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.29.0"),

    ],
    targets: [
        .executableTarget(
            name: "socktainer",
            dependencies: [
                .product(name: "ContainerClient", package: "container"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras")
            ]
        ),
        .testTarget(
            name: "socktainerTests",
            dependencies: ["socktainer"]
        ),

    ]

)
