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
            url: "https://raw.githubusercontent.com/nuxieio/rive-ios/799693f7df4d6bbd9c587a6195d9c925a4f12307/RiveRuntime.xcframework.zip",
            checksum: "e1a7434ac2b31f284796775bd49646b732d36adaa49260d81aa4b8b372eac888"
        )
    ]
)
