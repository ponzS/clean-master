// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CleanMaster",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "clean-master", targets: ["CleanMaster"])],
    targets: [
        .target(name: "CleanMasterCore"),
        .executableTarget(name: "CleanMaster", dependencies: ["CleanMasterCore"]),
        .testTarget(name: "CleanMasterCoreTests", dependencies: ["CleanMasterCore"])
    ]
)
