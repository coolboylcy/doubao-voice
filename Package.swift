// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DoubaoVoice",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DoubaoVoice", targets: ["DoubaoVoice"]),
    ],
    targets: [
        .executableTarget(
            name: "DoubaoVoice",
            path: "Sources/DoubaoVoice"
        ),
    ]
)
