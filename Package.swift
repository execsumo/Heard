// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingTranscriber",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "MeetingTranscriber", targets: ["MeetingTranscriber"])
    ],
    targets: [
        .executableTarget(
            name: "MeetingTranscriber",
            path: "Sources/MeetingTranscriber"
        )
    ]
)
