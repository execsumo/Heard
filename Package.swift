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
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .target(
            name: "MeetingTranscriberCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/MeetingTranscriberCore"
        ),
        .executableTarget(
            name: "MeetingTranscriber",
            dependencies: ["MeetingTranscriberCore"],
            path: "Sources/MeetingTranscriber"
        ),
        .executableTarget(
            name: "MeetingTranscriberTests",
            dependencies: ["MeetingTranscriberCore"],
            path: "Tests/MeetingTranscriberTests"
        )
    ]
)
