// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Engram",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Engram", targets: ["Engram"]),
        .executable(name: "engram", targets: ["CLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "Engram"),
        .executableTarget(
            name: "CLI",
            dependencies: [
                "Engram",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "EngramTests",
            dependencies: ["Engram"]
        ),
    ]
)
