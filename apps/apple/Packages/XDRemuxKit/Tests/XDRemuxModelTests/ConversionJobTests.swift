import Foundation
import XCTest
@testable import XDRemuxModel

/// In-memory file system: a set of existing paths plus a log of operations.
private final class FakeFS: ConversionFileSystem, @unchecked Sendable {
    let lock = NSLock()
    var files: Set<String> = []
    var dirs: Set<String> = []
    var log: [String] = []

    func fileExists(_ url: URL) -> Bool { lock.withLock { files.contains(url.path) } }
    func createDirectory(_ url: URL) throws { lock.withLock { dirs.insert(url.path); log.append("mkdir \(url.lastPathComponent)") } }
    func moveItem(from: URL, to: URL) throws {
        try lock.withLock {
            guard files.remove(from.path) != nil else { throw CocoaError(.fileNoSuchFile) }
            files.insert(to.path); log.append("mv \(from.lastPathComponent) -> \(to.lastPathComponent)")
        }
    }
    func removeItem(_ url: URL) throws {
        lock.withLock {
            files.remove(url.path); dirs.remove(url.path)
            files = files.filter { !$0.hasPrefix(url.path + "/") }
            log.append("rm \(url.lastPathComponent)")
        }
    }
}

private struct FakeBackend: ConversionBackend {
    var outcome: ConversionOutcome
    var verifies = true
    var writesOutput = true
    let fs: FakeFS

    func convert(input: String, output: String, config: RustConvertConfig,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> ConversionOutcome {
        progress(0.5)
        if writesOutput && outcome.success { fs.lock.withLock { _ = fs.files.insert(output) } }
        return outcome
    }
    func verifyOutput(path: String, styles: Bool, portrait: Bool) async throws -> Bool {
        verifyCalls?.append("\(styles),\(portrait)")
        return verifies
    }
    var verifyCalls: Log?
}

private final class Log: @unchecked Sendable {
    let lock = NSLock()
    var lines: [String] = []
    func append(_ s: String) { lock.withLock { lines.append(s) } }
}

/// Fake that also records PS3 injections.
private struct FakeStylesBackend: ConversionBackend, Styles3Backend {
    let fs: FakeFS
    let injections = Progress()
    var injectionFails = false

    func convert(input: String, output: String, config: RustConvertConfig,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> ConversionOutcome {
        fs.lock.withLock { _ = fs.files.insert(output) }
        return ConversionOutcome(success: true, mode: "lhdr", family: "x7")
    }
    func verifyOutput(path: String, styles: Bool, portrait: Bool) async throws -> Bool { true }
    func injectStyles3(path: String, grainSeed: UInt64) async throws {
        if injectionFails { throw CocoaError(.fileWriteUnknown) }
        injections.record(Double(grainSeed))
    }
}

/// Fake whose conversion blocks until the task is cancelled, like the core
/// stopping at its next tile after `xdremux_progress_cancel`.
private struct SlowBackend: ConversionBackend {
    let fs: FakeFS
    func convert(input: String, output: String, config: RustConvertConfig,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> ConversionOutcome {
        fs.lock.withLock { _ = fs.files.insert(output) } // partial file
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        return ConversionOutcome(success: false, errorMessage: "conversion cancelled")
    }
    func verifyOutput(path: String, styles: Bool, portrait: Bool) async throws -> Bool { true }
}

final class ConversionJobTests: XCTestCase {
    let scratch = URL(fileURLWithPath: "/scratch")
    let outRoot = URL(fileURLWithPath: "/out")
    let input = URL(fileURLWithPath: "/in/IMG0001.heic")

    func testVerifyFlagsFollowAppleOptions() async throws {
        let fs = FakeFS()
        var backend = FakeBackend(outcome: ConversionOutcome(success: true), fs: fs)
        let calls = Log()
        backend.verifyCalls = calls
        let job = ConversionJob(backend: backend, scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        var config = ConversionConfig()
        _ = try await job.run(input: input, config: config)
        config.outputMode = .apple; config.applePhotographicStyles = true; config.applePortrait = true
        _ = try await job.run(input: input, config: config)
        config.outputMode = .oppo // styles/portrait are gated off in OPPO mode
        _ = try await job.run(input: input, config: config)
        XCTAssertEqual(calls.lines, ["false,false", "true,true", "false,false"])
    }

    func testStyles3InjectsAfterVerificationInAppleMode() async throws {
        let fs = FakeFS()
        let backend = FakeStylesBackend(fs: fs)
        let job = ConversionJob(backend: backend, scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        var config = ConversionConfig()
        config.outputMode = .apple; config.applePhotographicStyles3 = true
        let product = try await job.run(input: input, config: config)
        XCTAssertTrue(fs.fileExists(product.outputURL))
        XCTAssertEqual(backend.injections.values, [Double(ConversionJob.grainSeed(for: "IMG0001.heic"))])
        // Same hash as the Dart `_grainSeedFor` for this name.
        XCTAssertEqual(ConversionJob.grainSeed(for: "IMG0001.heic"), 1130307681)
    }

    func testStyles3IsSkippedInOppoMode() async throws {
        let fs = FakeFS()
        let backend = FakeStylesBackend(fs: fs)
        let job = ConversionJob(backend: backend, scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        var config = ConversionConfig()
        config.outputMode = .oppo; config.applePhotographicStyles3 = true
        _ = try await job.run(input: input, config: config)
        XCTAssertTrue(backend.injections.values.isEmpty)
    }

    func testStyles3FailurePublishesNothing() async throws {
        let fs = FakeFS()
        var backend = FakeStylesBackend(fs: fs)
        backend.injectionFails = true
        let job = ConversionJob(backend: backend, scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        var config = ConversionConfig()
        config.outputMode = .apple; config.applePhotographicStyles3 = true
        do {
            _ = try await job.run(input: input, config: config)
            XCTFail("expected styles3Failed")
        } catch ConversionJobError.styles3Failed {
            XCTAssertFalse(fs.fileExists(URL(fileURLWithPath: "/out/IMG0001_iso.heic")))
            XCTAssertTrue(fs.files.isEmpty, "scratch cleaned: \(fs.files)")
        }
    }

    func testCancellationPublishesNothingAndCleansScratch() async throws {
        let fs = FakeFS()
        let job = ConversionJob(backend: SlowBackend(fs: fs), scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        let input = self.input
        let task = Task { try await job.run(input: input, config: ConversionConfig()) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            XCTAssertTrue(fs.files.isEmpty, "partial output removed: \(fs.files)")
        }
    }

    func testSuccessPublishesVerifiedOutput() async throws {
        let fs = FakeFS()
        let backend = FakeBackend(outcome: ConversionOutcome(success: true, mode: "lhdr", family: "x7", edrScale: 2.5, gainMapMax: 3), fs: fs)
        let job = ConversionJob(backend: backend, scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        let seen = Progress()
        let product = try await job.run(input: input, config: ConversionConfig()) { seen.record($0) }
        XCTAssertEqual(product.outputURL.path, "/out/IMG0001_iso.heic")
        XCTAssertEqual(product.outcome.family, "x7")
        XCTAssertTrue(fs.fileExists(product.outputURL))
        XCTAssertEqual(seen.values.last, 1)
        XCTAssertTrue(fs.log.contains { $0.hasPrefix("mv IMG0001_iso.heic") })
        XCTAssertTrue(fs.log.last?.hasPrefix("rm ") == true, "scratch dir cleaned up: \(fs.log)")
    }

    func testSourceNameDecidesPublishedName() async throws {
        let fs = FakeFS()
        let backend = FakeBackend(outcome: ConversionOutcome(success: true), fs: fs)
        let job = ConversionJob(backend: backend, scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        let copy = URL(fileURLWithPath: "/in/5F3A-IMG0001.heic")
        let product = try await job.run(input: copy, sourceName: "IMG0001.heic", config: ConversionConfig())
        XCTAssertEqual(product.outputURL.lastPathComponent, "IMG0001_iso.heic")
    }

    func testCoreFailureLeavesNoOutput() async {
        let fs = FakeFS()
        let backend = FakeBackend(outcome: ConversionOutcome(success: false, errorMessage: "not ProXDR"), fs: fs)
        let job = ConversionJob(backend: backend, scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        do {
            _ = try await job.run(input: input, config: ConversionConfig())
            XCTFail("expected failure")
        } catch let e as ConversionJobError {
            XCTAssertEqual(e, .coreFailed("not ProXDR"))
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(fs.files.isEmpty)
    }

    func testVerificationFailureDiscardsFile() async {
        let fs = FakeFS()
        let backend = FakeBackend(outcome: ConversionOutcome(success: true), verifies: false, fs: fs)
        let job = ConversionJob(backend: backend, scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        do {
            _ = try await job.run(input: input, config: ConversionConfig())
            XCTFail("expected failure")
        } catch let e as ConversionJobError {
            XCTAssertEqual(e, .verificationFailed)
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(fs.files.isEmpty, "\(fs.files)")
    }

    func testSuccessWithoutFileIsMissingOutput() async {
        let fs = FakeFS()
        let backend = FakeBackend(outcome: ConversionOutcome(success: true), writesOutput: false, fs: fs)
        let job = ConversionJob(backend: backend, scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        do {
            _ = try await job.run(input: input, config: ConversionConfig())
            XCTFail("expected failure")
        } catch let e as ConversionJobError {
            XCTAssertEqual(e, .missingOutput)
        } catch { XCTFail("\(error)") }
    }

    func testSkipExistingOffAppendsCounter() async throws {
        let fs = FakeFS()
        fs.files.insert("/out/IMG0001_iso.heic")
        var config = ConversionConfig()
        config.skipExisting = false
        let backend = FakeBackend(outcome: ConversionOutcome(success: true), fs: fs)
        let job = ConversionJob(backend: backend, scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        let product = try await job.run(input: input, config: config)
        XCTAssertEqual(product.outputURL.lastPathComponent, "IMG0001_iso (2).heic")
        XCTAssertTrue(fs.fileExists(URL(fileURLWithPath: "/out/IMG0001_iso.heic")), "original kept")
    }

    func testSkipExistingOnReplaces() async throws {
        let fs = FakeFS()
        fs.files.insert("/out/IMG0001_iso.heic")
        let backend = FakeBackend(outcome: ConversionOutcome(success: true), fs: fs)
        let job = ConversionJob(backend: backend, scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        let product = try await job.run(input: input, config: ConversionConfig())
        XCTAssertEqual(product.outputURL.lastPathComponent, "IMG0001_iso.heic")
        XCTAssertEqual(fs.files.count, 1)
    }

    func testCategorizeByModeUsesModeFolder() async throws {
        let fs = FakeFS()
        var config = ConversionConfig()
        config.categorizeOutputByMode = true
        config.outputMode = .apple
        let backend = FakeBackend(outcome: ConversionOutcome(success: true), fs: fs)
        let job = ConversionJob(backend: backend, scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        let product = try await job.run(input: input, config: config)
        XCTAssertEqual(product.outputURL.path, "/out/Apple 标准/IMG0001_iso.heic")
    }

    func testSamePathRefused() async {
        let fs = FakeFS()
        var config = ConversionConfig()
        config.fileNameSuffix = ""
        let backend = FakeBackend(outcome: ConversionOutcome(success: true), fs: fs)
        let job = ConversionJob(backend: backend, scratchRoot: scratch, outputRoot: URL(fileURLWithPath: "/in"), fileSystem: fs)
        do {
            _ = try await job.run(input: input, config: config)
            XCTFail("expected refusal")
        } catch let e as ConversionJobError {
            XCTAssertEqual(e, .samePath)
        } catch { XCTFail("\(error)") }
    }
}

final class OutputPlannerTests: XCTestCase {
    func testFileNameKeepsStemAndAddsSuffix() {
        XCTAssertEqual(OutputPlanner.publishedFileName(forInput: "IMG20260807.heic", config: ConversionConfig()), "IMG20260807_iso.heic")
        var c = ConversionConfig(); c.fileNameSuffix = "_hdr"
        XCTAssertEqual(OutputPlanner.publishedFileName(forInput: "photo.JPG", config: c), "photo_hdr.heic")
    }

    func testUniqueURLCounts() {
        let taken: Set<String> = ["/o/a.heic", "/o/a (2).heic"]
        let u = OutputPlanner.uniqueURL(URL(fileURLWithPath: "/o/a.heic")) { taken.contains($0.path) }
        XCTAssertEqual(u.lastPathComponent, "a (3).heic")
    }
}

final class SettingsStoreTests: XCTestCase {
    func testRoundTripAndFallback() throws {
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        let store = SettingsStore(read: { box.data }, write: { box.data = $0 })
        XCTAssertEqual(store.load(), ConversionConfig())
        var c = ConversionConfig(); c.outputMode = .apple; c.applePortrait = true
        try store.save(c)
        XCTAssertEqual(store.load(), c)
        box.data = Data("garbage".utf8)
        XCTAssertEqual(store.load(), ConversionConfig())
    }
}

private final class Progress: @unchecked Sendable {
    let lock = NSLock()
    var values: [Double] = []
    func record(_ v: Double) { lock.withLock { values.append(v) } }
}

// MARK: - Motion Photo paths

private struct FakeMotionBackend: ConversionBackend, MotionPhotoBackend {
    let fs: FakeFS
    var isMotion = true
    var pairValid = true

    func convert(input: String, output: String, config: RustConvertConfig,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> ConversionOutcome {
        fs.lock.withLock { _ = fs.files.insert(output) }
        return ConversionOutcome(success: true, mode: "lhdr", family: "x7")
    }
    func verifyOutput(path: String, styles: Bool, portrait: Bool) async throws -> Bool { true }
    func motionPhotoInfo(path: String) async throws -> MotionPhotoInfo? {
        isMotion ? MotionPhotoInfo(sourceKind: "oppoLpex", durationMs: 3000) : nil
    }
    func makeLivePhoto(source: String, still: String, outputDirectory: String) async throws -> LivePhotoFiles {
        let stem = ((source as NSString).lastPathComponent as NSString).deletingPathExtension
        let s = "\(outputDirectory)/\(stem).heic", v = "\(outputDirectory)/\(stem).mov"
        fs.lock.withLock { fs.files.insert(s); fs.files.insert(v) }
        return LivePhotoFiles(stillPath: s, videoPath: v, contentIdentifier: "ABC")
    }
    func livePhotoPairIsValid(still: String, video: String) async throws -> Bool { pairValid }
    func splitMotionPhotoVideos(path: String, outputDirectory: String) async throws -> [String] {
        let v = "\(outputDirectory)/x.video.mp4", p = "\(outputDirectory)/x.primary.mp4"
        fs.lock.withLock { fs.files.insert(v); fs.files.insert(p) }
        return [v, p]
    }
}

final class MotionPhotoJobTests: XCTestCase {
    let scratch = URL(fileURLWithPath: "/scratch")
    let outRoot = URL(fileURLWithPath: "/out")
    let input = URL(fileURLWithPath: "/in/IMG_M.jpg")

    func testLivePhotoPairPublishesStillAndMov() async throws {
        let fs = FakeFS()
        let job = ConversionJob(backend: FakeMotionBackend(fs: fs), scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        let p = try await job.run(input: input, config: ConversionConfig(), motionMode: .livePhotoPair)
        XCTAssertEqual(p.outputURL.path, "/out/IMG_M_iso.heic")
        XCTAssertEqual(p.pairedVideoURL?.path, "/out/IMG_M_iso.mov")
        XCTAssertTrue(p.isLivePhoto)
        XCTAssertEqual(Set(fs.files), ["/out/IMG_M_iso.heic", "/out/IMG_M_iso.mov"], "scratch files gone: \(fs.files)")
    }

    func testInvalidPairFailsWithoutPublishing() async {
        let fs = FakeFS()
        let job = ConversionJob(backend: FakeMotionBackend(fs: fs, pairValid: false), scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        do {
            _ = try await job.run(input: input, config: ConversionConfig(), motionMode: .livePhotoPair)
            XCTFail("expected failure")
        } catch let e as ConversionJobError {
            if case .livePhotoFailed = e {} else { XCTFail("\(e)") }
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(fs.files.isEmpty, "\(fs.files)")
    }

    func testStillOnlyIgnoresVideo() async throws {
        let fs = FakeFS()
        let job = ConversionJob(backend: FakeMotionBackend(fs: fs), scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        let p = try await job.run(input: input, config: ConversionConfig(), motionMode: .still)
        XCTAssertNil(p.pairedVideoURL)
        XCTAssertEqual(fs.files, ["/out/IMG_M_iso.heic"])
    }

    func testStillAndVideoExportsClips() async throws {
        let fs = FakeFS()
        let job = ConversionJob(backend: FakeMotionBackend(fs: fs), scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        let p = try await job.run(input: input, config: ConversionConfig(), motionMode: .stillAndVideo)
        XCTAssertEqual(Set(p.extraVideoURLs.map(\.lastPathComponent)), ["IMG_M_iso.motion.mp4", "IMG_M_iso.primary.mp4"])
        XCTAssertEqual(p.allFiles.count, 3)
    }

    func testNonMotionPhotoIgnoresMode() async throws {
        let fs = FakeFS()
        let job = ConversionJob(backend: FakeMotionBackend(fs: fs, isMotion: false), scratchRoot: scratch, outputRoot: outRoot, fileSystem: fs)
        let p = try await job.run(input: input, config: ConversionConfig(), motionMode: .livePhotoPair)
        XCTAssertNil(p.pairedVideoURL)
        XCTAssertEqual(fs.files, ["/out/IMG_M_iso.heic"])
    }
}

// MARK: - Round trip

private struct FakeWriteback: WritebackBackend {
    let fs: FakeFS
    var report: WritebackReport
    var writes = true
    func writebackReturnedPhoto(original: String?, returned: String, output: String,
                                outputMode: OutputMode, restoreWatermark: Bool) async throws -> WritebackReport {
        if writes { fs.lock.withLock { _ = fs.files.insert(output) } }
        return report
    }
}

final class RoundTripTests: XCTestCase {
    let out = URL(fileURLWithPath: "/out"), scratch = URL(fileURLWithPath: "/scratch")
    let returned = URL(fileURLWithPath: "/in/IMG_1234.HEIC"), donor = URL(fileURLWithPath: "/in/IMG20260802.heic")

    func testEditCopyConfigForcesAppleStyles() {
        var base = ConversionConfig(); base.outputMode = .oppo; base.applePortrait = true; base.fileNameSuffix = "_x"
        let c = RoundTrip.editCopyConfig(base: base)
        XCTAssertEqual(c.outputMode, .apple)
        XCTAssertEqual(c.rustConfig, RustConvertConfig(oppoCompat: 0, oppoCameraTail: 0, strictTmap: 0, applePhotographicStyles: 1, applePortrait: 0))
        XCTAssertEqual(OutputPlanner.publishedFileName(forInput: "IMG20260802.heic", config: c), "IMG20260802.apple-edit.heic")
    }

    func testFinalURLNaming() {
        XCTAssertEqual(RoundTrip.finalURL(returnedName: "IMG_1234.HEIC", outputMode: .oppo, outputRoot: out).lastPathComponent, "IMG_1234.oppo-final.heic")
        XCTAssertEqual(RoundTrip.finalURL(returnedName: "IMG_1234.HEIC", outputMode: .apple, outputRoot: out).lastPathComponent, "IMG_1234.apple-final.heic")
    }

    func testOppoWritebackNeedsDonor() async {
        let fs = FakeFS()
        do {
            _ = try await RoundTrip.writeback(donor: nil, returned: returned, outputMode: .oppo, restoreWatermark: false,
                                              outputRoot: out, scratchRoot: scratch,
                                              backend: FakeWriteback(fs: fs, report: WritebackReport(success: true)), fileSystem: fs)
            XCTFail()
        } catch { XCTAssertEqual(error as? RoundTripError, .donorRequired) }
    }

    func testUsableReportPublishes() async throws {
        let fs = FakeFS()
        let report = WritebackReport(success: true, outputValid: true, rasterWatermarkRestored: true, restoredOppoEntries: ["oplus"])
        let (url, r) = try await RoundTrip.writeback(donor: donor, returned: returned, outputMode: .oppo, restoreWatermark: true,
                                                     outputRoot: out, scratchRoot: scratch,
                                                     backend: FakeWriteback(fs: fs, report: report), fileSystem: fs)
        XCTAssertEqual(url.path, "/out/IMG_1234.oppo-final.heic")
        XCTAssertEqual(r.restoredOppoEntries, ["oplus"])
        XCTAssertEqual(fs.files, ["/out/IMG_1234.oppo-final.heic"])
    }

    func testInvalidOutputIsRejected() async {
        let fs = FakeFS()
        do {
            _ = try await RoundTrip.writeback(donor: donor, returned: returned, outputMode: .apple, restoreWatermark: false,
                                              outputRoot: out, scratchRoot: scratch,
                                              backend: FakeWriteback(fs: fs, report: WritebackReport(success: true, outputValid: false)), fileSystem: fs)
            XCTFail()
        } catch {
            if case .writebackFailed = error as? RoundTripError {} else { XCTFail("\(error)") }
        }
        XCTAssertTrue(fs.files.isEmpty)
    }
}
