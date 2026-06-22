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
            url: "https://raw.githubusercontent.com/nuxieio/rive-ios/47b6d0da992927b2e1a6bb56192c5d4f100c5f7a/RiveRuntime.xcframework.zip",
            checksum: "9def52bc85eacce94ea1691f91c627723439e122f5faeaa0fe8ee11aeeb660b3"
        )
    ]
)
