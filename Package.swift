// swift-tools-version:5.9
// The macOS app target lives in the Xcode project. This package is the
// processing core: it builds and tests on Linux and is compiled into the
// DewrinkleCore framework by Xcode.
import PackageDescription

let package = Package(
    name: "Dewrinkle",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DewrinkleCore", targets: ["DewrinkleCore"])
    ],
    targets: [
        .target(name: "DewrinkleCore"),
        .testTarget(name: "DewrinkleCoreTests", dependencies: ["DewrinkleCore"])
    ]
)
