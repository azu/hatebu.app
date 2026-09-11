// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HatebuSearch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HatebuCore", targets: ["HatebuCore"]),
        .executable(name: "hatebu", targets: ["HatebuCLI"]),
        .executable(name: "HatebuSearch", targets: ["HatebuApp"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CBackground"),
        .target(name: "HatebuCore", dependencies: ["CSQLite", "CBackground"]),
        .executableTarget(name: "HatebuCLI", dependencies: ["HatebuCore", "CBackground"]),
        .executableTarget(name: "HatebuApp", dependencies: ["HatebuCore"]),
        .testTarget(name: "HatebuCoreTests", dependencies: ["HatebuCore"]),
        .testTarget(name: "HatebuAppTests", dependencies: ["HatebuApp", "HatebuCore"])
    ]
)
