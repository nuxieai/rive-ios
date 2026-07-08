// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RiveRuntime",
    platforms: [.iOS("14.0"), .visionOS("1.0"), .tvOS("16.0"), .macOS("13.1"), .macCatalyst("14.0")],
    products: [
        .library(
            name: "RiveRuntime",
            targets: ["RiveRuntime"])],
    targets: [
        .binaryTarget(
            name: "RiveRuntime",
            url: "https://raw.githubusercontent.com/nuxieio/rive-ios/26dc9047f39d488222e7e1a0de4d4092abc7e61f/RiveRuntime.xcframework.zip",
            checksum: "4998620385656b74529d9e8a6bb484becfea11c97846cf5cc35ad4413268ea0e"
        )
    ]
)
