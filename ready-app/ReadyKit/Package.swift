// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ReadyKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "ReadyScoring", targets: ["ReadyScoring"]),
        .library(name: "ReadyHealthKit", targets: ["ReadyHealthKit"]),
    ],
    targets: [
        .target(
            name: "ReadyScoring"
        ),
        .target(
            name: "ReadyHealthKit",
            dependencies: ["ReadyScoring"]
        ),
        .target(
            name: "ReadyTestSupport",
            dependencies: ["ReadyScoring"]
        ),
        .testTarget(
            name: "ReadyScoringTests",
            dependencies: ["ReadyScoring", "ReadyTestSupport"]
        ),
        .testTarget(
            name: "ReadyHealthKitTests",
            dependencies: ["ReadyHealthKit", "ReadyTestSupport"]
        ),
    ]
)
