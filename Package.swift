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
    ],
    targets: [
        .executableTarget(
            name: "socktainer",
            dependencies: [
                .product(name: "ContainerClient", package: "container"),
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
        .testTarget(
            name: "socktainerTests",
            dependencies: ["socktainer"]
        ),

    ]

)
