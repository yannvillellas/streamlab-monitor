// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamLabMonitor",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "StreamLabModel", targets: ["StreamLabModel"]),
        .library(name: "StreamLabSignalling", targets: ["StreamLabSignalling"]),
        .library(name: "StreamLabStorage", targets: ["StreamLabStorage"]),
        .executable(name: "streamlab-demo", targets: ["StreamLabDemo"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [
                .apt(["libsqlite3-dev"]),
                .yum(["sqlite-devel"]),
                .brew(["sqlite"]),
            ]
        ),
        .target(name: "StreamLabModel"),
        .target(name: "StreamLabSignalling", dependencies: ["StreamLabModel"]),
        .target(name: "StreamLabStorage", dependencies: ["StreamLabModel", "CSQLite"]),
        .executableTarget(
            name: "StreamLabDemo",
            dependencies: ["StreamLabModel", "StreamLabSignalling", "StreamLabStorage"]
        ),
        .testTarget(name: "StreamLabModelTests", dependencies: ["StreamLabModel"]),
        .testTarget(
            name: "StreamLabSignallingTests",
            dependencies: ["StreamLabSignalling", "StreamLabModel"]
        ),
        .testTarget(
            name: "StreamLabStorageTests",
            dependencies: ["StreamLabStorage", "StreamLabModel"]
        ),
    ]
)
