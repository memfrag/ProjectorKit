// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "Projector",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ProjectorKit", targets: ["ProjectorKit"]),
        .executable(name: "projector", targets: ["projector"]),
    ],
    dependencies: [
        // Pinned exactly: any upstream serialization-style change alters our
        // output bytes, so upgrades must re-baseline the golden fixtures.
        .package(url: "https://github.com/tuist/XcodeProj.git", exact: "9.14.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "ProjectorKit",
            dependencies: [
                .product(name: "XcodeProj", package: "XcodeProj"),
            ]
        ),
        .executableTarget(
            name: "projector",
            dependencies: [
                "ProjectorKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "ProjectorKitTests",
            dependencies: ["ProjectorKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["projector"]
        ),
    ]
)
