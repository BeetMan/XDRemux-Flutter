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
        .package(
            url: "https://github.com/21Z121Z1/XDRemux.git",
            exact: "1.3.1"
        )
    ],
    targets: [
        .target(
            name: "XDRemuxFlutterBackend",
            dependencies: [
                .product(name: "XDRemuxCore", package: "xdremux"),
                .product(name: "XDRemuxAppleFeatures", package: "xdremux")
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
