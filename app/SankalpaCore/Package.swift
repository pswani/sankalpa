// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SankalpaCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SankalpaCore", targets: ["SankalpaCore"]),
        .library(name: "SankalpaStorage", targets: ["SankalpaStorage"]),
        .library(name: "SankalpaVoice", targets: ["SankalpaVoice"])
    ],
    targets: [
        .target(
            name: "SankalpaCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SankalpaCoreTests",
            dependencies: ["SankalpaCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Persistence and the one place instants become dates. A library target rather than app
        // code, so the failure paths that matter most — an unreadable file, a failed write — can
        // actually be tested.
        .target(
            name: "SankalpaStorage",
            dependencies: ["SankalpaCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SankalpaStorageTests",
            dependencies: ["SankalpaStorage", "SankalpaCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SankalpaVoice",
            dependencies: ["SankalpaCore"],
            resources: [.process("Interpretation/voice-interpreter-v1.txt")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SankalpaVoiceTests",
            dependencies: ["SankalpaVoice", "SankalpaCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
