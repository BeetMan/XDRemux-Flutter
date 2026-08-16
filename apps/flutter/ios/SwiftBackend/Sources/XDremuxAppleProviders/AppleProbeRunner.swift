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
        // strdup the argv storage: array-element temporaries in a .map
        // closure may be released immediately under -O, which made argv
        // point at freed memory in release builds (the debug layout kept
        // it alive by luck).
        var cStrings: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
        defer {
            for ptr in cStrings { free(ptr) }
        }
        var argv: [UnsafePointer<CChar>] = cStrings.map { UnsafePointer($0!) }
        let outcome = probe(Int32(argv.count), &argv)
        return AppleNativeToolchain.Result(
            status: outcome.status,
            stdout: outcome.stdoutData,
            stderr: outcome.stderrData,
            timedOut: false)
    }
}
#endif
