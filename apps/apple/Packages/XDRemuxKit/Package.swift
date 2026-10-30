// swift-tools-version: 6.0

import PackageDescription

// Native Apple front-end packages for XDRemux (see docs/plans/apple-native.md §2).
//
//   XDRemuxCore   binaryTarget → ../../Frameworks/XDRemuxCore.xcframework
//                 (Rust core + x265, produced by xdremux/rust/build_apple.sh; not in Git)
//   XDRemuxKit    Swift wrapper over the C ABI: background execution, Codable
//                 reports, RAII release of Rust-owned memory, progress stream.
//   XDRemuxModel  Pure Swift business model (config, queue, checkpoint). No UI,
//                 no platform frameworks, so it runs under `swift test` on CI.
//   xdremux       macOS command-line front-end over the same Kit/Model
//                 (`swift build -c release --product xdremux`).
let package = Package(
    name: "XDRemuxKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "XDRemuxKit", targets: ["XDRemuxKit"]),
        .library(name: "XDRemuxModel", targets: ["XDRemuxModel"]),
        .executable(name: "xdremux", targets: ["xdremux"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .binaryTarget(
            name: "XDRemuxCore",
            path: "../../Frameworks/XDRemuxCore.xcframework"
        ),
        .target(
            name: "XDRemuxKit",
            dependencies: ["XDRemuxCore", "XDRemuxModel"],
            linkerSettings: [
                // x265 is C++; the Rust staticlib does not carry its own link flags.
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "XDRemuxModel"
        ),
        .executableTarget(
            name: "xdremux",
            dependencies: [
                "XDRemuxKit", "XDRemuxModel",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/xdremux-cli"
        ),
        .testTarget(
            name: "XDRemuxKitTests",
            dependencies: ["XDRemuxKit"]
        ),
        .testTarget(
            name: "XDRemuxModelTests",
            dependencies: ["XDRemuxModel"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
