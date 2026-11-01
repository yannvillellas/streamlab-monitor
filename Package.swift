// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamLabMonitor",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "StreamLabModel", targets: ["StreamLabModel"]),
        .library(name: "StreamLabSignalling", targets: ["StreamLabSignalling"]),
        .executable(name: "streamlab-demo", targets: ["StreamLabDemo"]),
    ],
    targets: [
        .target(name: "StreamLabModel"),
        .target(name: "StreamLabSignalling", dependencies: ["StreamLabModel"]),
        .executableTarget(name: "StreamLabDemo", dependencies: ["StreamLabModel", "StreamLabSignalling"]),
        .testTarget(name: "StreamLabModelTests", dependencies: ["StreamLabModel"]),
        .testTarget(
            name: "StreamLabSignallingTests",
            dependencies: ["StreamLabSignalling", "StreamLabModel"]
        ),
    ]
)
