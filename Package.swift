// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lurk",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "Lurk", targets: ["Lurk"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .target(
            name: "LurkCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/LurkCore"
        ),
        .executableTarget(
            name: "Lurk",
            dependencies: ["LurkCore"],
            path: "Sources/Lurk"
        ),
        .executableTarget(
            name: "LurkTests",
            dependencies: ["LurkCore"],
            path: "Tests/LurkTests"
        )
    ]
)
