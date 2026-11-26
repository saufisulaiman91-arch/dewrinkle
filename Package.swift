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
        .target(
            name: "DewrinkleRendering",
            dependencies: ["DewrinkleCore"],
            path: "App",
            exclude: [
                "DewrinkleApp.swift",
                "Dewrinkle.entitlements",
                "Info.plist",
                "Assets.xcassets",
                "Shaders",
                "UI",
                "Masking"
            ]
        ),
        .testTarget(name: "DewrinkleCoreTests", dependencies: ["DewrinkleCore"]),
        .testTarget(name: "DewrinkleRenderingTests", dependencies: ["DewrinkleRendering", "DewrinkleCore"])
    ]
)
