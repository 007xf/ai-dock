// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AIDock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AIDock",
            path: "Sources/AIDock",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
