// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "hls-transcode",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "hls-transcode", path: "Sources")
    ]
)
