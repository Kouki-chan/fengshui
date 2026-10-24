// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FengshuiKit",
    platforms: [.iOS("26.0"), .watchOS(.v10), .macOS(.v15)],
    products: [
        .library(name: "FengshuiKit", targets: ["FengshuiKit"]),
    ],
    targets: [
        .target(
            name: "FengshuiKit",
            resources: [.copy("Resources/schema_v1.sql")]
        ),
        .testTarget(name: "FengshuiKitTests", dependencies: ["FengshuiKit"]),
    ]
)
