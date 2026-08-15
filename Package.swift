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
        // Portable Aurora core compiled from aurora-core via
        // scripts/build-auroracore-xcframework.sh. Build it before `swift build`
        // / `swift test`. Owns wire encoding, AdmissionProof handling, and the
        // cover-issuance carrier codec (Aurora spec Section 35.10).
        .binaryTarget(
            name: "AuroraCoreFFI",
            path: "Vendor/AuroraCore.xcframework"
        ),
        .target(
            name: "AuroraKit",
            dependencies: ["AuroraCoreFFI"],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedLibrary("resolv"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(name: "AuroraUI", dependencies: ["AuroraKit"]),
        .testTarget(name: "AuroraKitTests", dependencies: ["AuroraKit"]),
    ]
)
