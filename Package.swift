// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Heard",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "Heard", targets: ["Heard"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .target(
            name: "HeardCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/HeardCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "Heard",
            dependencies: ["HeardCore"],
            path: "Sources/Heard",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "HeardTests",
            dependencies: ["HeardCore"],
            path: "Tests/HeardTests"
        )
    ]
)
