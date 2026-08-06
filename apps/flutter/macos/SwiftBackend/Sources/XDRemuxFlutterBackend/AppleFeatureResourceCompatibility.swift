import Darwin
import Foundation
import ObjectiveC.runtime

/// Small, versioned compatibility overlay for upstream Apple feature helper
/// resources. The upstream v1.3.1 helper was compiled against a private
/// `PLPhotoEditSource` initializer that changed on newer macOS releases.
///
/// The overlay is created in the app cache and selected through the upstream
/// `XDREMUX_APPLE_PLATFORM_ROOT` hook. No upstream checkout is modified, and
/// the feature capability remains closed when the host API cannot be proven.
enum AppleFeatureResourceCompatibility {
    struct Status {
        let available: Bool
        let reason: String
    }

    private static let lock = NSLock()
    private static var cachedStatus: Status?

    static func prepare() -> Status {
        lock.lock()
        defer { lock.unlock() }
        if let cachedStatus {
            return cachedStatus
        }

        let status = makeStatus()
        cachedStatus = status
        return status
    }

    private static func makeStatus() -> Status {
        loadPhotosPrivateFrameworks()
        guard let sourceClass = NSClassFromString("PLPhotoEditSource") as? NSObject.Type else {
            return Status(
                available: false,
                reason: "当前 macOS 未提供 PLPhotoEditSource，Apple Photographic Styles 保持关闭。"
            )
        }

        let currentSelector = "initWithURL:type:useEmbeddedPreview:"
        let upstreamSelector = "initWithURL:type:image:useEmbeddedPreview:"
        if sourceClass.instancesRespond(to: Selector(upstreamSelector)) {
            return Status(available: true, reason: "")
        }
        guard sourceClass.instancesRespond(to: Selector(currentSelector)) else {
            return Status(
                available: false,
                reason: "PLPhotoEditSource 不支持上游 v1.3.1 所需初始化 API，Apple Photographic Styles 保持关闭。"
            )
        }

        do {
            try installThreeArgumentPhotoEditSourceOverlay()
            return Status(available: true, reason: "")
        } catch {
            return Status(
                available: false,
                reason: "无法安装 Apple Photographic Styles resource compatibility overlay：\(error)"
            )
        }
    }

    private static func loadPhotosPrivateFrameworks() {
        let paths = [
            "/System/Library/PrivateFrameworks/NeutrinoCore.framework/NeutrinoCore",
            "/System/Library/PrivateFrameworks/PhotoImaging.framework/PhotoImaging",
            "/System/Library/PrivateFrameworks/PhotosUICore.framework/PhotosUICore",
            "/System/Library/PrivateFrameworks/PhotosUIPrivate.framework/PhotosUIPrivate",
        ]
        for path in paths {
            _ = dlopen(path, RTLD_NOW | RTLD_GLOBAL)
        }
    }

    private static func installThreeArgumentPhotoEditSourceOverlay() throws {
        let fileManager = FileManager.default
        guard let cachesURL = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw CompatibilityError.cacheDirectoryUnavailable
        }

        let rootURL = cachesURL
            .appendingPathComponent("com.xdremux", isDirectory: true)
            .appendingPathComponent("AppleFeatureCompatibility", isDirectory: true)
            .appendingPathComponent("xdremux-1.3.1-plphotoedit-source-3arg", isDirectory: true)
        let resourceRootURL = rootURL.appendingPathComponent("ApplePlatform", isDirectory: true)
        let nativeURL = resourceRootURL.appendingPathComponent("Native", isDirectory: true)
        let outputURL = nativeURL.appendingPathComponent(
            "learnnode_coefficient_probe.m",
            isDirectory: false
        )

        if !fileManager.isReadableFile(atPath: outputURL.path) {
            guard let sourceURL = locateUpstreamResource() else {
                throw CompatibilityError.upstreamResourceUnavailable
            }
            let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
            let oldText = """
            id sourceObject = ((id (*)(id, SEL, id, id, id, BOOL))objc_msgSend)(
                    [sourceClass alloc],
                    NSSelectorFromString(@"initWithURL:type:image:useEmbeddedPreview:"),
                    photoURL, @"public.heic", nil, NO
                );
            """.data(using: .utf8)!
            let newText = """
            id sourceObject = ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                    [sourceClass alloc],
                    NSSelectorFromString(@"initWithURL:type:useEmbeddedPreview:"),
                    photoURL, @"public.heic", NO
                );
            """.data(using: .utf8)!
            guard let patchedData = replacing(sourceData, old: oldText, new: newText) else {
                throw CompatibilityError.upstreamResourceShapeChanged
            }

            try fileManager.createDirectory(at: nativeURL, withIntermediateDirectories: true)
            try patchedData.write(to: outputURL, options: [.atomic])
        }

        guard setenv("XDREMUX_APPLE_PLATFORM_ROOT", resourceRootURL.path, 1) == 0 else {
            throw CompatibilityError.environmentUpdateFailed
        }
    }

    private static func locateUpstreamResource() -> URL? {
        let resourceName = "learnnode_coefficient_probe"
        let bundleName = "XDRemux_XDRemuxAppleFeatures"
        var bundles = [Bundle.main]
        bundles.append(contentsOf: Bundle.allBundles)
        bundles.append(contentsOf: Bundle.allFrameworks)

        var seen = Set<String>()
        for bundle in bundles {
            guard seen.insert(bundle.bundleURL.path).inserted else { continue }

            if let direct = bundle.url(
                forResource: resourceName,
                withExtension: "m",
                subdirectory: "ApplePlatform/Native"
            ), FileManager.default.isReadableFile(atPath: direct.path) {
                return direct
            }

            guard let resourceBundle = bundle.url(
                forResource: bundleName,
                withExtension: "bundle"
            ) else {
                continue
            }
            let candidates = [
                resourceBundle
                    .appendingPathComponent("Contents/Resources/ApplePlatform/Native", isDirectory: true)
                    .appendingPathComponent("\(resourceName).m"),
                resourceBundle
                    .appendingPathComponent("ApplePlatform/Native", isDirectory: true)
                    .appendingPathComponent("\(resourceName).m"),
            ]
            if let match = candidates.first(where: {
                FileManager.default.isReadableFile(atPath: $0.path)
            }) {
                return match
            }
        }
        return nil
    }

    private static func replacing(_ data: Data, old: Data, new: Data) -> Data? {
        guard let range = data.range(of: old) else { return nil }
        var result = Data(data[..<range.lowerBound])
        result.append(new)
        result.append(data[range.upperBound...])
        return result
    }

    private enum CompatibilityError: LocalizedError {
        case cacheDirectoryUnavailable
        case upstreamResourceUnavailable
        case upstreamResourceShapeChanged
        case environmentUpdateFailed

        var errorDescription: String? {
            switch self {
            case .cacheDirectoryUnavailable:
                return "无法定位 app cache 目录"
            case .upstreamResourceUnavailable:
                return "找不到 XDRemuxAppleFeatures 的 learnnode resource"
            case .upstreamResourceShapeChanged:
                return "上游 learnnode resource 已改变，未应用 selector 替换"
            case .environmentUpdateFailed:
                return "无法设置 XDREMUX_APPLE_PLATFORM_ROOT"
            }
        }
    }
}
