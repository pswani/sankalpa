// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SankalpaCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SankalpaCore", targets: ["SankalpaCore"]),
        .library(name: "SankalpaStorage", targets: ["SankalpaStorage"])
    ],
    targets: [
        .target(name: "SankalpaStorage", dependencies: ["SankalpaCore"]),
        .testTarget(name: "SankalpaStorageTests", dependencies: ["SankalpaStorage", "SankalpaCore"]),
        .target(
            name: "SankalpaCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SankalpaCoreTests",
            dependencies: ["SankalpaCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
