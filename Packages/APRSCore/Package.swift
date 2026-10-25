// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "APRSCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "APRSCore", targets: ["APRSCore"]),
    ],
    targets: [
        .target(name: "APRSCore"),
        .testTarget(name: "APRSCoreTests", dependencies: ["APRSCore"]),
    ]
)
