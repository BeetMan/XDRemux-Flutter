// swift-tools-version: 6.0

import PackageDescription

// iOS backend package: vendored copy of upstream XDRemux v1.3.1
// (XDRemuxCore + XDremuxAppleFeatures) with iOS platform support.
//
// Upstream only declares .macOS(.v15) and relies on runtime-compiled
// helper executables (Process + swiftc/clang/xcrun) that cannot exist on
// iOS. This vendored copy adds .iOS(.v15) and replaces the process-based
// helpers with in-process providers behind `#if canImport(UIKit)` gates.
//
// Target names follow the upstream manifest exactly (module names must
// match the `import` statements in the vendored sources): module
// `XDRemuxCore` lives in Sources/XDremuxCore, module `XDremuxAppleFeatures`
// in Sources/XDremuxAppleFeatures.
//
// Re-vendor procedure (upgrade to a newer upstream release):
//   git -C <swiftpm cache>/XDRemux-* archive <tag>:Sources/XDremuxCore | tar -x -C Sources/XDremuxCore
//   git -C <swiftpm cache>/XDRemux-* archive <tag>:Sources/XDremuxAppleFeatures | tar -x -C Sources/XDremuxAppleFeatures
// then re-apply the iOS patches (search for `canImport(UIKit)`).
let package = Package(
    name: "XDRemuxFlutterBackendIOS",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15),
        .iOS(.v15),
    ],
    products: [
        .library(name: "XDRemuxCore", targets: ["XDRemuxCore"]),
        .library(name: "XDremuxAppleFeatures", targets: ["XDremuxAppleFeatures"]),
    ],
    targets: [
        .target(
            name: "XDRemuxCore",
            path: "Sources/XDremuxCore",
            resources: [
                .copy("Resources/Native"),
            ]
        ),
        .target(
            name: "XDremuxAppleFeatures",
            dependencies: ["XDRemuxCore"],
            resources: [
                .copy("Resources/ApplePlatform"),
            ]
        ),
        .testTarget(
            name: "XDRemuxFlutterBackendIOSTests",
            dependencies: ["XDremuxAppleFeatures"],
            path: "Tests/XDRemuxFlutterBackendIOSTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
