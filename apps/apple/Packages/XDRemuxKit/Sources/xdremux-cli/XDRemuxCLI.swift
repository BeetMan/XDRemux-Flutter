import ArgumentParser
import Foundation
import XDRemuxKit
import XDRemuxModel

/// `xdremux`: command-line front-end over the same Kit/Model the macOS app
/// uses, so scripts get identical output rules (temp path → verify → publish,
/// `<stem><suffix>.heic`, mode folders) and identical Rust config bytes.
@main
struct XDRemuxCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xdremux",
        abstract: "Convert OPPO / OnePlus / realme ProXDR photos to ISO 21496-1 HDR HEIC.",
        discussion: """
            Output modes: `oppo` (OPPO 兼容) restores the OPPO-compatible structure, \
            metadata and private tail so the file behaves like an original in the \
            ColorOS gallery; `apple` (Apple 标准) adds no OPPO private data and is \
            editable in Apple Photos. Rust core \(XDRemuxEngine.coreVersion()).
            """,
        version: XDRemuxEngine.coreVersion(),
        subcommands: [Convert.self, EditCopy.self, Writeback.self, Inspect.self, Plan.self, Classify.self, Details.self,
                      Verify.self, Capabilities.self],
        defaultSubcommand: Convert.self)
}

// MARK: - Shared option groups

struct InputFiles: ParsableArguments {
    @Argument(help: "Input photos (.heic / .heif / .jpg). Directories are expanded one level, non-image files skipped.",
              completion: .file(extensions: ["heic", "heif", "HEIC", "jpg", "jpeg", "JPG"]))
    var inputs: [String]

    func resolved() throws -> [URL] {
        var urls: [URL] = []
        let fm = FileManager.default
        for path in inputs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
                throw ValidationError("no such file: \(path)")
            }
            if isDir.boolValue {
                let names = try fm.contentsOfDirectory(atPath: path).sorted()
                urls += names
                    .filter { ["heic", "heif", "jpg", "jpeg"].contains(($0 as NSString).pathExtension.lowercased()) }
                    .map { URL(fileURLWithPath: path).appendingPathComponent($0) }
            } else {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        guard !urls.isEmpty else { throw ValidationError("no input photos") }
        return urls
    }
}

struct OutputFormat: ParsableArguments {
    @Flag(name: .long, help: "Machine-readable JSON (one object per input, newline-delimited).")
    var json = false
}

struct ConversionOptions: ParsableArguments {
    @Option(name: [.customShort("m"), .long], help: "Output mode: oppo (OPPO 兼容) or apple (Apple 标准).")
    var mode: OutputMode = .oppo

    @Option(name: .long, help: "OPPO compatibility policy (oppo mode): \(OppoCompatMode.allCases.map(\.rawValue).joined(separator: ", ")).")
    var compat: OppoCompatMode = .on

    @Option(name: .long, help: "OPPO camera tail policy (oppo mode): \(OppoCameraTailMode.allCases.map(\.rawValue).joined(separator: ", ")).")
    var cameraTail: OppoCameraTailMode = .automatic

    @Flag(name: .long, help: "Strict ISO 21496-1 tmap payload instead of the ImageIO-compatible one.")
    var strictTmap = false

    @Flag(name: .long, help: "Apple Photographic Styles graph (apple mode).")
    var styles = false

    @Flag(name: .long, help: "Photographic Styles 3 texture/grain (apple mode; implies --styles).")
    var styles3 = false

    @Flag(name: .long, help: "Apple Portrait data (apple mode).")
    var portrait = false

    @Option(name: .long, help: "Family override: auto, x6, x7.")
    var family: Family = .auto

    @Option(name: .long, help: "File name suffix before .heic.")
    var suffix = "_iso"

    @Flag(name: .long, inversion: .prefixedNo, help: "Replace an existing output of the same name (default) or append a counter.")
    var overwrite = true

    @Flag(name: .long, help: "Put outputs under an 'OPPO 兼容' / 'Apple 标准' folder.")
    var categorize = false

    var config: ConversionConfig {
        var c = ConversionConfig()
        c.outputMode = mode
        c.oppoCompatibility = compat
        c.oppoCameraTail = cameraTail
        c.strictTmap = strictTmap
        c.applePhotographicStyles = styles || styles3
        c.applePhotographicStyles3 = styles3
        c.applePortrait = portrait
        c.family = family
        c.fileNameSuffix = suffix
        c.skipExisting = overwrite
        c.categorizeOutputByMode = categorize
        return c
    }
}

extension OutputMode: ExpressibleByArgument {}
extension OppoCompatMode: ExpressibleByArgument {}
extension OppoCameraTailMode: ExpressibleByArgument {}
extension Family: ExpressibleByArgument {}

// MARK: - convert

struct Convert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Convert one or more photos (default command).",
        discussion: "Each output is written to a temporary path, verified with the core's decoder and structure check, then published. Inputs are never modified. Exit status is 1 when any input failed.")

    @OptionGroup var files: InputFiles
    @OptionGroup var options: ConversionOptions
    @OptionGroup var format: OutputFormat

    @Option(name: [.short, .customLong("output-dir")], help: "Directory for outputs (default: next to each input).",
            completion: .directory)
    var outputDir: String?

    @Flag(name: .shortAndLong, help: "No progress on stderr.")
    var quiet = false

    @Flag(name: .shortAndLong, help: "Keep the x265 encoder's own log lines on stderr (silenced by default).")
    var verbose = false

    mutating func run() async throws {
        let inputs = try files.resolved()
        let config = options.config
        // x265 writes its [info]/[warning] lines straight to fd 2 and would
        // tear the progress bar; keep our own stderr on a duplicate fd.
        let console = StderrConsole(silenceOriginal: !verbose)
        defer { console.restore() }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("xdremux-cli-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        var failures = 0
        let interrupt = InterruptWatcher()
        defer { interrupt.stop() }
        for (index, input) in inputs.enumerated() {
            if interrupt.triggered { break }
            let outputRoot = outputDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? input.deletingLastPathComponent()
            let job = ConversionJob(backend: XDRemuxEngine.shared, scratchRoot: scratch, outputRoot: outputRoot)
            let label = "[\(index + 1)/\(inputs.count)] \(input.lastPathComponent)"
            let reporter = ProgressReporter(label: label, enabled: !quiet && !format.json, console: console)
            do {
                // Ctrl-C cancels the running task; the core stops at its next
                // tile and the partial output is discarded with the scratch dir.
                let work = Task { try await job.run(input: input, config: config) { reporter.update($0) } }
                interrupt.onInterrupt = { work.cancel() }
                let product = try await work.value
                reporter.finish()
                if format.json {
                    emitJSON(["input": input.path, "output": product.outputURL.path, "success": true,
                              "mode": product.outcome.mode as Any, "family": product.outcome.family as Any,
                              "edrScale": product.outcome.edrScale, "gainMapMax": product.outcome.gainMapMax,
                              "outputMode": config.outputMode.rawValue])
                } else {
                    print("\(label) → \(product.outputURL.path)")
                }
            } catch is CancellationError {
                reporter.finish()
                if format.json {
                    emitJSON(["input": input.path, "success": false, "cancelled": true])
                } else {
                    console.write("\(label) 已取消\n")
                }
                throw ExitCode(130)
            } catch {
                failures += 1
                reporter.finish()
                let message = describe(error)
                if format.json {
                    emitJSON(["input": input.path, "success": false, "error": message])
                } else {
                    console.write("\(label) 失败：\(message)\n")
                }
            }
        }
        if !format.json, inputs.count > 1 {
            print("完成 \(inputs.count - failures)/\(inputs.count)")
        }
        if failures > 0 { throw ExitCode(1) }
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case ConversionJobError.coreFailed(let m): return m ?? "core failed"
        case ConversionJobError.verificationFailed: return "output failed verification and was discarded"
        case ConversionJobError.styles3Failed(let m): return "Photographic Styles 3 post-process failed: \(m ?? "unknown")"
        case ConversionJobError.missingOutput: return "core reported success but wrote no file"
        case ConversionJobError.samePath: return "output path equals input path"
        default: return String(describing: error)
        }
    }
}

/// SIGINT → `onInterrupt` (once). The default handler is replaced so the
/// process can finish cleanly: cancel the core, delete scratch, exit 130.
final class InterruptWatcher: @unchecked Sendable {
    private let source: DispatchSourceSignal
    private let lock = NSLock()
    private var _triggered = false
    var onInterrupt: (@Sendable () -> Void)?

    var triggered: Bool { lock.withLock { _triggered } }

    init() {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let handler: (@Sendable () -> Void)? = self.lock.withLock {
                self._triggered = true
                return self.onInterrupt
            }
            handler?()
        }
        source.resume()
    }

    func stop() {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
}

/// Our stderr, kept on a private duplicate of fd 2 so the original fd can be
/// pointed at /dev/null while the Rust core (x265) runs.
final class StderrConsole: @unchecked Sendable {
    private let handle: FileHandle
    private let savedFD: Int32
    private let silenced: Bool

    init(silenceOriginal: Bool) {
        savedFD = dup(STDERR_FILENO)
        handle = FileHandle(fileDescriptor: savedFD, closeOnDealloc: false)
        silenced = silenceOriginal
        if silenceOriginal {
            let null = open("/dev/null", O_WRONLY)
            if null >= 0 {
                dup2(null, STDERR_FILENO)
                close(null)
            }
        }
    }

    func write(_ text: String) {
        handle.write(Data(text.utf8))
    }

    func restore() {
        if silenced { dup2(savedFD, STDERR_FILENO) }
    }

    deinit { close(savedFD) }
}

/// Single-line stderr progress bar; silent when disabled.
final class ProgressReporter: @unchecked Sendable {
    private let label: String
    private let enabled: Bool
    private let console: StderrConsole
    private let lock = NSLock()
    private var lastPercent = -1

    init(label: String, enabled: Bool, console: StderrConsole) {
        self.label = label
        self.enabled = enabled
        self.console = console
    }

    func update(_ fraction: Double) {
        guard enabled else { return }
        let percent = Int((fraction * 100).rounded())
        lock.withLock {
            guard percent != lastPercent else { return }
            lastPercent = percent
            let filled = percent / 5
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled)
            console.write("\r\(label) \(bar) \(percent)%")
        }
    }

    func finish() {
        guard enabled else { return }
        console.write("\r\u{1B}[2K")
    }
}

// MARK: - round trip: edit-copy / writeback

struct EditCopy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit-copy",
        abstract: "Step 2 of the OPPO ↔ Apple round trip: make an Apple Photographic Styles edit copy of an OPPO original.",
        discussion: "Writes <stem>.apple-edit.heic. Transfer it to an iPhone, edit in Apple Photos, export the result and feed it to `writeback` together with the same OPPO original as --donor.")

    @OptionGroup var files: InputFiles
    @OptionGroup var format: OutputFormat
    @Option(name: [.short, .customLong("output-dir")], help: "Directory for outputs (default: next to each input).", completion: .directory)
    var outputDir: String?
    @Flag(name: .shortAndLong, help: "Keep x265 log lines on stderr.")
    var verbose = false

    mutating func run() async throws {
        let console = StderrConsole(silenceOriginal: !verbose)
        defer { console.restore() }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("xdremux-cli-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var failures = 0
        for input in try files.resolved() {
            let root = outputDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? input.deletingLastPathComponent()
            let job = ConversionJob(backend: XDRemuxEngine.shared, scratchRoot: scratch, outputRoot: root)
            do {
                let product = try await RoundTrip.createEditCopy(donor: input, base: ConversionConfig(), job: job)
                if format.json { emitJSON(["input": input.path, "editCopy": product.outputURL.path, "success": true]) }
                else { print("\(input.lastPathComponent) → \(product.outputURL.path)") }
            } catch {
                failures += 1
                if format.json { emitJSON(["input": input.path, "success": false, "error": String(describing: error)]) }
                else { console.write("\(input.lastPathComponent) 失败：\(error)\n") }
            }
        }
        if failures > 0 { throw ExitCode(1) }
    }
}

struct Writeback: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Step 4 of the round trip: write the iPhone-returned photo back with the OPPO donor's watermark and metadata.",
        discussion: "Writes <returned stem>.<mode>-final.heic. OPPO 兼容 output and --restore-watermark both require --donor.")

    @Argument(help: "The photo returned from Apple Photos (.heic).", completion: .file(extensions: ["heic", "HEIC", "heif"]))
    var returned: String
    @Option(name: .long, help: "The original OPPO photo used as donor for watermark, metadata and OPPO tail.", completion: .file())
    var donor: String?
    @Option(name: [.customShort("m"), .long], help: "oppo (OPPO 兼容) or apple (Apple 标准).")
    var mode: OutputMode = .oppo
    @Flag(name: .long, inversion: .prefixedNo, help: "Restore the visible original watermark from the donor (default on).")
    var restoreWatermark = true
    @Option(name: [.short, .customLong("output-dir")], help: "Directory for the output (default: next to the returned photo).", completion: .directory)
    var outputDir: String?
    @OptionGroup var format: OutputFormat
    @Flag(name: .shortAndLong, help: "Keep x265 log lines on stderr.")
    var verbose = false

    mutating func run() async throws {
        let console = StderrConsole(silenceOriginal: !verbose)
        defer { console.restore() }
        let returnedURL = URL(fileURLWithPath: returned)
        let root = outputDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? returnedURL.deletingLastPathComponent()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("xdremux-cli-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let (url, report) = try await RoundTrip.writeback(
                donor: donor.map(URL.init(fileURLWithPath:)), returned: returnedURL, outputMode: mode,
                restoreWatermark: restoreWatermark, outputRoot: root, scratchRoot: scratch, backend: XDRemuxEngine.shared)
            if format.json {
                emitJSON(["returned": returned, "donor": donor as Any, "output": url.path, "success": true,
                          "rasterWatermarkRestored": report.rasterWatermarkRestored as Any,
                          "restoredOppoEntries": report.restoredOppoEntries as Any,
                          "exifGrafted": report.exifGrafted as Any, "timingsMs": report.timingsMs as Any])
            } else {
                print("\(returnedURL.lastPathComponent) → \(url.path)")
                if let w = report.rasterWatermarkRestored { print("  原机水印恢复: \(w ? "是" : "否")") }
                if let e = report.restoredOppoEntries, !e.isEmpty { print("  恢复的 OPPO 条目: \(e.joined(separator: ", "))") }
            }
        } catch {
            let message: String
            switch error {
            case RoundTripError.donorRequired: message = "OPPO 兼容输出或恢复水印需要 --donor"
            case RoundTripError.writebackFailed(let m): message = m ?? "writeback failed"
            case RoundTripError.outputMissing: message = "core reported success but wrote no file"
            default: message = String(describing: error)
            }
            if format.json { emitJSON(["returned": returned, "success": false, "error": message]) }
            else { console.write("写回失败：\(message)\n") }
            throw ExitCode(1)
        }
    }
}

// MARK: - inspect / classify / details / verify / capabilities

struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check whether photos are convertible ProXDR / Ultra HDR sources (no output written).")
    @OptionGroup var files: InputFiles
    @OptionGroup var format: OutputFormat

    mutating func run() async throws {
        var failures = 0
        for input in try files.resolved() {
            let r = try await XDRemuxEngine.shared.inspect(path: input.path)
            if !r.success { failures += 1 }
            if format.json {
                emitJSON(["input": input.path, "success": r.success, "mode": r.mode as Any, "family": r.family as Any,
                          "edrScale": r.edrScale, "gainMapMax": r.gainMapMax, "error": r.errorMessage as Any])
            } else if r.success {
                print("\(input.lastPathComponent): \(r.family ?? "?") \(r.mode ?? "?") edr=\(fmt(r.edrScale)) gainMax=\(fmt(r.gainMapMax))")
            } else {
                print("\(input.lastPathComponent): 不可转换（\(r.errorMessage ?? "unknown")）")
            }
        }
        if failures > 0 { throw ExitCode(1) }
    }
}

struct Classify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Capture-mode classification (the OPPO UserComment flags).")
    @OptionGroup var files: InputFiles
    @OptionGroup var format: OutputFormat

    mutating func run() async throws {
        for input in try files.resolved() {
            let c = try await XDRemuxEngine.shared.classify(path: input.path)
            if format.json {
                emitJSON(["input": input.path, "status": c.status as Any, "modeKey": c.modeKey as Any,
                          "folderName": c.folderName as Any, "hdrKind": c.hdrKind as Any, "family": c.family as Any,
                          "hasTagFlags": c.hasTagFlags, "tagFlags": String(c.tagFlags), "unknownFlags": String(c.unknownFlags)])
            } else {
                let bits = [c.family, c.hdrKind, c.modeKey, c.status].compactMap { $0 }.joined(separator: " · ")
                print("\(input.lastPathComponent): \(bits)")
            }
        }
    }
}

struct Details: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "EXIF / HDR / Apple editing-metadata summary.")
    @OptionGroup var files: InputFiles
    @OptionGroup var format: OutputFormat

    mutating func run() async throws {
        for input in try files.resolved() {
            let report = try await XDRemuxEngine.shared.photoDetails(path: input.path)
            if format.json {
                print(report.raw)
                continue
            }
            let d: PhotoDetails = try report.decode()
            print(input.lastPathComponent)
            let rows: [(String, String?)] = [
                ("设备", [d.make, d.model].compactMap { $0 }.joined(separator: " ")),
                ("尺寸", d.dimensionsText), ("时间", d.dateTime), ("曝光", d.exposureSummary),
                ("HDR", d.hdrKind), ("EDR scale", d.edrScale.map(fmt)), ("Gain map max", d.gainMapMax.map(fmt)),
                ("Apple 摄影风格", d.applePhotographicStyles == true ? "yes" : nil),
                ("Apple 人像", d.applePortrait == true ? "yes" : nil),
                ("错误", d.errorMessage),
            ]
            for (k, v) in rows where !(v ?? "").isEmpty {
                print("  \(k): \(v!)")
            }
        }
    }
}

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Decode and structure-check converted HEIC files. Exit 1 if any fails.")
    @OptionGroup var files: InputFiles
    @OptionGroup var format: OutputFormat

    mutating func run() async throws {
        var failures = 0
        for input in try files.resolved() {
            let ok = try await XDRemuxEngine.shared.verifyOutput(path: input.path)
            if !ok { failures += 1 }
            if format.json {
                emitJSON(["input": input.path, "valid": ok])
            } else {
                print("\(input.lastPathComponent): \(ok ? "OK" : "INVALID")")
            }
        }
        if failures > 0 { throw ExitCode(1) }
    }
}

struct Plan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the core's plan for each photo: classification, Huawei / Motion Photo policy, output name.",
        discussion: "This is xdremux_plan_output, the same decision every front-end uses before converting. Read-only.")

    @OptionGroup var files: InputFiles
    @OptionGroup var options: ConversionOptions
    @OptionGroup var format: OutputFormat

    mutating func run() async throws {
        let config = options.config
        for input in try files.resolved() {
            let plan = try await XDRemuxEngine.shared.planOutput(path: input.path, config: config)
            if format.json {
                emitJSON(["input": input.path, "convertible": plan.convertible as Any, "convertError": plan.convertError as Any,
                          "modeKey": plan.classification?.modeKey as Any, "folderName": plan.classification?.folderName as Any,
                          "hdrKind": plan.classification?.hdrKind as Any, "family": plan.classification?.family as Any,
                          "huaweiHdr": plan.huawei?.isHdr as Any, "isMotionPhoto": plan.isMotionPhoto as Any,
                          "admitted": plan.policy?.admitted as Any, "policyReason": plan.policy?.reason as Any,
                          "outputFileName": plan.output?.fileName as Any])
            } else {
                let c = plan.classification
                let policy = plan.policy.map { $0.admitted ? "admitted" : "skipped: \($0.reason ?? "")" } ?? "?"
                print("\(input.lastPathComponent): \(plan.convertible == true ? "convertible" : "not convertible")"
                      + " · \(c?.family ?? "-")/\(c?.hdrKind ?? "-") · \(c?.folderName ?? "uncategorized")"
                      + (plan.isMotionPhoto == true ? " · motion photo" : "") + " · \(policy) → \(plan.output?.fileName ?? "-")")
            }
        }
    }
}

struct Capabilities: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Encoder paths compiled into this core (JSON).")

    mutating func run() async throws {
        print(try await XDRemuxEngine.shared.codecCapabilities().raw)
    }
}

// MARK: - helpers

func emitJSON(_ object: [String: Any]) {
    let cleaned = object.compactMapValues { value -> Any? in
        if case Optional<Any>.none = value { return nil }
        return value
    }
    if let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func fmt(_ value: Double) -> String {
    String(format: "%.3f", value)
}
