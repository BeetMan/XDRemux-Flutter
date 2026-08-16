import Darwin
import Foundation

#if canImport(UIKit)
import XDremuxAppleFeatures
import XDremuxObjCSupport

/// In-process port of the upstream `apple_semantic_style_properties_probe.m`
/// validation helper (Sources/XDremuxAppleFeatures/Resources/ApplePlatform/
/// Validation). Interfaces are identical: argv[0] = style-metadata bplist
/// path, argv[1] = style-data readback output path; prints the same JSON
/// report to "stdout"; exit status 0 only when NeutrinoCore parsed the
/// metadata and the 51,840-byte style data readback was written.
///
/// Device probe (ApplePrivateAbiProbe, 2026-08-16) confirmed
/// `_NUSemanticStyleProperties` exists on iPhone iOS 27 and responds to
/// `semanticStylePropertiesFromImageMetadata:error:`.
enum AppleSemanticStylePropertiesValidator {

    static func run(arguments: [String]) -> AppleNativeToolchain.Result {
        guard arguments.count == 2 else {
            return AppleNativeToolchain.Result(
                status: 2,
                stdout: Data(),
                stderr: Data(
                    ("usage: apple-semantic-style-properties-probe "
                        + "style-metadata.bplist style-data-readback.bin\n").utf8),
                timedOut: false)
        }
        let metadataPath = arguments[0]
        let readbackPath = arguments[1]
        let metadata = FileManager.default.contents(atPath: metadataPath)

        // dlopen NeutrinoCore explicitly, mirroring the macOS helper (on
        // iOS the framework is usually already resident in-process;
        // RTLD_NOLOAD first keeps this strictly read-only when possible).
        let frameworkPath =
            "/System/Library/PrivateFrameworks/NeutrinoCore.framework/NeutrinoCore"
        let alreadyResident = dlopen(frameworkPath, RTLD_NOW | RTLD_NOLOAD) != nil
        let framework = dlopen(frameworkPath, RTLD_NOW | RTLD_NOLOAD)
            ?? (alreadyResident ? nil : dlopen(frameworkPath, RTLD_NOW))
        defer {
            if let framework, !alreadyResident {
                dlclose(framework)
            }
        }

        let propertiesClass = NSClassFromString("_NUSemanticStyleProperties")
        var parseError: NSError?
        var exception: NSException?
        var properties: AnyObject?

        if framework != nil, let propertiesClass, let metadata {
            properties = invokeParser(
                propertiesClass, metadata as NSData, &parseError, &exception)
        }

        var styleData: Data?
        if let properties {
            styleData = invokeStyleData(properties)
        }

        var readbackWritten = false
        if let styleData {
            readbackWritten = FileManager.default.createFile(
                atPath: readbackPath, contents: styleData)
        }

        let report: [String: Any] = [
            "schema": "xdremux-apple-semantic-style-properties-probe-v1",
            "frameworkLoaded": framework != nil,
            "classAvailable": propertiesClass != nil,
            "parseSucceeded": properties != nil,
            "styleDataLength": styleData?.count ?? 0,
            "readbackWritten": readbackWritten,
            "error": parseError.map { $0.description } ?? NSNull(),
            "exception": exception.map {
                ["name": $0.name ?? "", "reason": $0.reason ?? ""]
            } ?? NSNull(),
        ]
        var payload =
            (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
            ?? Data()
        payload.append(0x0A)
        let success = properties != nil && styleData?.count == 51_840 && readbackWritten
        return AppleNativeToolchain.Result(
            status: success ? 0 : 1,
            stdout: payload,
            stderr: Data(),
            timedOut: false)
    }

    /// Calls +[cls semanticStylePropertiesFromImageMetadata:error:] through
    /// the class-method IMP (the NSError** out-parameter is not directly
    /// callable from Swift), catching ObjC exceptions the way the macOS
    /// helper's out-of-process isolation would have.
    private static func invokeParser(
        _ cls: AnyClass,
        _ metadata: NSData,
        _ parseError: inout NSError?,
        _ exception: inout NSException?
    ) -> AnyObject? {
        let selector = NSSelectorFromString("semanticStylePropertiesFromImageMetadata:error:")
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        typealias Signature =
            @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>?)
                -> AnyObject?
        let function = unsafeBitCast(method_getImplementation(method), to: Signature.self)
        var captured: NSError?
        var output: AnyObject?
        exception = XDRemuxCatchException {
            output = function(cls, selector, metadata, &captured)
        }
        parseError = captured
        if exception != nil { output = nil }
        return output
    }

    /// Calls -[obj styleData] through the instance-method IMP.
    private static func invokeStyleData(_ object: AnyObject) -> Data? {
        let selector = NSSelectorFromString("styleData")
        guard let method = class_getInstanceMethod(type(of: object), selector) else { return nil }
        typealias Signature = @convention(c) (AnyObject, Selector) -> AnyObject?
        let function = unsafeBitCast(method_getImplementation(method), to: Signature.self)
        return function(object, selector) as? Data
    }
}
#endif
