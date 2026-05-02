// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Heard",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "Heard", targets: ["Heard"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.3"),
    ],
    targets: [
        .target(
            name: "HeardCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/HeardCore"
        ),
        .executableTarget(
            name: "Heard",
            dependencies: ["HeardCore"],
            path: "Sources/Heard"
        ),
        .executableTarget(
            name: "HeardTests",
            dependencies: ["HeardCore"],
            path: "Tests/HeardTests"
        )
    ]
)
