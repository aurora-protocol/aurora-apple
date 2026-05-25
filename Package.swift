// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AuroraApple",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AuroraKit", targets: ["AuroraKit"]),
        .library(name: "AuroraUI", targets: ["AuroraUI"]),
    ],
    targets: [
        .target(name: "AuroraKit"),
        .target(name: "AuroraUI", dependencies: ["AuroraKit"]),
        .testTarget(name: "AuroraKitTests", dependencies: ["AuroraKit"]),
    ]
)
