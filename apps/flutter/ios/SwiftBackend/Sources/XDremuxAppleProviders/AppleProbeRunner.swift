import Foundation

#if canImport(UIKit)
import XDremuxAppleFeatures
import XDremuxAppleProbes

/// Swift bridge between the run-level helper dispatch and the ported ObjC
/// probe mains (XDremuxAppleProbes target). Receives the helper argv
/// WITHOUT argv[0], prepends the helper name (the ported mains index
/// argv exactly like the upstream executables did), runs the probe in
/// process, and returns the captured streams.
enum AppleProbeRunner {
    static func runLearnNode(arguments: [String]) throws -> AppleNativeToolchain.Result {
        run(probe: XDRemuxRunLearnNodeProbe, name: "learnnode-coefficient-probe",
            arguments: arguments)
    }

    static func runStyleScenePayload(arguments: [String]) throws -> AppleNativeToolchain.Result {
        run(probe: XDRemuxRunStyleScenePayloadProbe,
            name: "apple-style-scene-payload-producer", arguments: arguments)
    }

    private static func run(
        probe: (Int32, UnsafeMutablePointer<UnsafePointer<CChar>>?) -> XDRemuxProbeOutcome,
        name: String,
        arguments: [String]
    ) -> AppleNativeToolchain.Result {
        let argvStrings = [name] + arguments
        let storage: [[CChar]] = argvStrings.map { Array($0.utf8CString) }
        let pointers: [UnsafePointer<CChar>] = storage.map { buffer in
            buffer.withUnsafeBufferPointer { $0.baseAddress! }
        }
        var mutablePointers: [UnsafePointer<CChar>] = pointers
        let outcome = mutablePointers.withUnsafeMutableBufferPointer { ptr in
            probe(
                Int32(pointers.count),
                UnsafeMutableRawPointer(ptr.baseAddress!)!
                    .assumingMemoryBound(to: UnsafePointer<CChar>.self))
        }
        return AppleNativeToolchain.Result(
            status: outcome.status,
            stdout: outcome.stdoutData,
            stderr: outcome.stderrData,
            timedOut: false)
    }
}
#endif
