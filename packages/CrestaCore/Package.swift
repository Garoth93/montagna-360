// swift-tools-version: 5.9
// Logic package for the Cresta app. Pure Swift (Foundation only):
// it must build and test on Linux with `swift test`.
import PackageDescription

let package = Package(
    name: "CrestaCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "CrestaCore", targets: ["CrestaCore"])
    ],
    targets: [
        .target(name: "CrestaCore", path: "Sources/CrestaCore"),
        .testTarget(name: "CrestaCoreTests", dependencies: ["CrestaCore"], path: "Tests/CrestaCoreTests")
    ]
)
