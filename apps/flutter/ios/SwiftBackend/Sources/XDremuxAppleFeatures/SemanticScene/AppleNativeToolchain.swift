import Foundation
import Darwin
import XDRemuxCore

package enum AppleNativeToolchain {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data
        let timedOut: Bool
    }

    #if canImport(UIKit)
    // iOS: Process does not exist, so the macOS pattern (compile helper
    // sources with swiftc/clang at runtime, then run them) is impossible.
    // The pipeline call sites keep their signatures; every helper entry
    // point throws until the corresponding in-process provider is
    // installed (Phase 2 of the iOS port).
    static func semanticExecutable() throws -> URL {
        throw CLIError.invalidContainer(
            "iOS: apple-vision-semantic-mattes requires the in-process Vision provider (not installed)")
    }

    static func learnExecutable() throws -> URL {
        throw CLIError.invalidContainer(
            "iOS: learnnode-coefficient-probe requires the in-process provider (not installed)")
    }

    static func styleScenePayloadExecutable() throws -> URL {
        throw CLIError.invalidContainer(
            "iOS: apple-style-scene-payload-producer requires the in-process provider (not installed)")
    }

    static func hevcEncoderExecutable() throws -> URL {
        throw CLIError.invalidContainer(
            "iOS: apple-vt-hevc-encoder runs via DirectTiledHEVCGainMapEncoder.inProcessEncoder (not installed)")
    }

    static func stylePropertiesProbeExecutable() throws -> URL {
        throw CLIError.invalidContainer(
            "iOS: apple-semantic-style-properties-probe requires the in-process provider (not installed)")
    }

    static func run(
        _ executableURL: URL,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) throws -> Result {
        throw CLIError.invalidContainer(
            "iOS cannot launch helper processes; in-process providers are required")
    }
    #else
    private static let compileLock = NSLock()

    static func semanticExecutable() throws -> URL {
        let source = try resourceURL(
            subdirectory: "Native",
            name: "apple_vision_semantic_mattes.swift"
        )
        return try compile(
            source: source,
            executableName: "apple-vision-semantic-mattes",
            arguments: ["swiftc", "-O", source.path]
        )
    }

    static func learnExecutable() throws -> URL {
        let source = try resourceURL(
            subdirectory: "Native",
            name: "learnnode_coefficient_probe.m"
        )
        return try compile(
            source: source,
            executableName: "learnnode-coefficient-probe",
            arguments: [
                "clang", "-O2", "-fobjc-arc", "-fblocks",
                "-framework", "AppKit",
                "-framework", "Foundation",
                "-framework", "CoreImage",
                "-framework", "ImageIO",
                "-framework", "Metal",
                "-framework", "CoreGraphics",
                "-framework", "CoreVideo",
                "-lz",
                source.path,
            ]
        )
    }

    static func styleScenePayloadExecutable() throws -> URL {
        let source = try resourceURL(
            subdirectory: "Native",
            name: "apple_style_scene_payload_probe.m"
        )
        return try compile(
            source: source,
            executableName: "apple-style-scene-payload-producer",
            arguments: [
                "clang", "-O2", "-fobjc-arc", "-fblocks",
                "-framework", "Foundation",
                "-framework", "CoreGraphics",
                "-framework", "CoreVideo",
                "-framework", "Metal",
                source.path,
            ]
        )
    }

    static func hevcEncoderExecutable() throws -> URL {
        try DirectTiledHEVCGainMapEncoder.helperExecutable()
    }

    static func stylePropertiesProbeExecutable() throws -> URL {
        let source = try resourceURL(
            subdirectory: "Validation",
            name: "apple_semantic_style_properties_probe.m"
        )
        return try compile(
            source: source,
            executableName: "apple-semantic-style-properties-probe",
            arguments: [
                "clang", "-fobjc-arc",
                "-framework", "Foundation",
                source.path,
            ]
        )
    }

    static func run(
        _ executableURL: URL,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSemaphore.signal() }
        do {
            try process.run()
        } catch {
            throw CLIError.invalidContainer(
                "cannot launch Apple feature helper \(executableURL.lastPathComponent): \(error)"
            )
        }
        let readGroup = DispatchGroup()
        let readLock = NSLock()
        var stdout = Data()
        var stderr = Data()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let value = output.fileHandleForReading.readDataToEndOfFile()
            readLock.lock()
            stdout = value
            readLock.unlock()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let value = errors.fileHandleForReading.readDataToEndOfFile()
            readLock.lock()
            stderr = value
            readLock.unlock()
            readGroup.leave()
        }
        let waitResult: DispatchTimeoutResult
        if let timeout {
            waitResult = exitSemaphore.wait(timeout: .now() + timeout)
        } else {
            exitSemaphore.wait()
            waitResult = .success
        }
        let timedOut = waitResult == .timedOut
        if timedOut, process.isRunning {
            process.terminate()
            if exitSemaphore.wait(timeout: .now() + 1) == .timedOut,
               process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        readGroup.wait()
        readLock.lock()
        let capturedStdout = stdout
        let capturedStderr = stderr
        readLock.unlock()
        return Result(
            status: process.terminationStatus,
            stdout: capturedStdout,
            stderr: capturedStderr,
            timedOut: timedOut
        )
    }

    private static func resourceURL(subdirectory: String, name: String) throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["XDREMUX_APPLE_PLATFORM_ROOT"] {
            candidates.append(
                URL(fileURLWithPath: override, isDirectory: true)
                    .appendingPathComponent(subdirectory, isDirectory: true)
                    .appendingPathComponent(name)
            )
        }
        if let resources = Bundle.module.resourceURL {
            candidates.append(
                resources.appendingPathComponent("ApplePlatform", isDirectory: true)
                    .appendingPathComponent(subdirectory, isDirectory: true)
                    .appendingPathComponent(name)
            )
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(
                resources.appendingPathComponent("ApplePlatform", isDirectory: true)
                .appendingPathComponent(subdirectory, isDirectory: true)
                .appendingPathComponent(name)
            )
        }
        if let match = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return match
        }
        throw CLIError.invalidContainer(
            "missing XDRemux Apple feature resource \(subdirectory)/\(name)"
        )
    }

    private static func compile(
        source: URL,
        executableName: String,
        arguments: [String]
    ) throws -> URL {
        let sourceData = try Data(contentsOf: source, options: [.mappedIfSafe])
        var cacheIdentity = sourceData
        let normalizedArguments = arguments.map { argument in
            argument == source.path ? "<source>" : argument
        }.joined(separator: "\u{0}")
        cacheIdentity.append(contentsOf: normalizedArguments.utf8)
        let sourceHash = sha256Hex(cacheIdentity)
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CLIError.invalidContainer("cannot resolve the user cache directory")
        }
        let directory = caches
            .appendingPathComponent("com.proxdr.XDRemux", isDirectory: true)
            .appendingPathComponent("AppleNativeTools", isDirectory: true)
            .appendingPathComponent(sourceHash, isDirectory: true)
        let executable = directory.appendingPathComponent(executableName)

        compileLock.lock()
        defer { compileLock.unlock() }
        if FileManager.default.isExecutableFile(atPath: executable.path) {
            return executable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: arguments + ["-o", executable.path]
        )
        guard result.status == 0, FileManager.default.isExecutableFile(atPath: executable.path) else {
            let diagnostic = String(data: result.stderr, encoding: .utf8) ?? "unknown compiler error"
            throw CLIError.invalidContainer(
                "cannot build \(executableName): \(diagnostic.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return executable
    }
    #endif
}
