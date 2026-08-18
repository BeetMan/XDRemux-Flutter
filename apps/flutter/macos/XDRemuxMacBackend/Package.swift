// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "XDRemuxFlutterBackend",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "XDRemuxFlutterBackend",
            targets: ["XDRemuxFlutterBackend"]
        ),
        .executable(
            name: "xdremux-portrait-research",
            targets: ["XDRemuxPortraitResearch"]
        )
    ],
    dependencies: [
        // Use the vendored package shared with the iOS backend so macOS and
        // iOS compile the same patched XDRemuxCore sources.
        .package(path: "../../ios/SwiftBackend")
    ],
    targets: [
        .target(
            name: "XDRemuxFlutterBackend",
            dependencies: [
                .product(name: "XDRemuxCore", package: "SwiftBackend"),
                .product(name: "XDremuxAppleFeatures", package: "SwiftBackend")
            ]
        ),
        .executableTarget(
            name: "XDRemuxPortraitResearch",
            dependencies: ["XDRemuxFlutterBackend"]
        ),
        .testTarget(
            name: "XDRemuxFlutterBackendTests",
            dependencies: ["XDRemuxFlutterBackend"]
        )
    ],
    swiftLanguageModes: [.v5]
)
