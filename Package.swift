// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "JobRunner",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "JobRunner",
            targets: ["JobRunner"]
        ),
        .library(
            name: "JobRunnerExamples",
            targets: ["JobRunnerExamples"]
        ),
    ],
    targets: [
        .target(
            name: "JobRunner",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "JobRunnerExamples",
            dependencies: ["JobRunner"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "JobRunnerTests",
            dependencies: ["JobRunner"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
