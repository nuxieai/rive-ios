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
            url: "https://github.com/nuxieio/rive-ios/releases/download/6.20.3-nuxie.1/RiveRuntime.xcframework.zip",
            checksum: "85516df375959b00169fd7565cbb318b33fd49c930272a507a8356a0efeafedf"
        )
    ]
)
