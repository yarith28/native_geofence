// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RegionRegistrationCoordinatorTests",
    platforms: [
        .macOS(.v13),
        .iOS(.v14),
    ],
    targets: [
        .target(name: "RegionRegistrationCore"),
        .testTarget(
            name: "RegionRegistrationCoreTests",
            dependencies: ["RegionRegistrationCore"]
        ),
    ]
)
