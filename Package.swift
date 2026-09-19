// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceDoggo",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VoiceDoggo", targets: ["VoiceDoggo"]),
    ],
    targets: [
        .executableTarget(
            name: "VoiceDoggo",
            path: "Sources/VoiceDoggo"
        ),
    ]
)
