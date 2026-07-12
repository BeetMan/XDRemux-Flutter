import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message):
            return message
        }
    }
}

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure.assertion(message)
    }
}

@MainActor
func makeTempDirectory(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("xdremuxapp-model-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor
func writeFile(_ url: URL, bytes: Int = 16) throws {
    try Data(repeating: 0x41, count: bytes).write(to: url)
}

@main
struct XDRemuxAppModelTests {
    @MainActor
    static func main() async throws {
        try await testImportDiscoversHEICFilesAndDeduplicates()
        try await testImportedRowsStartWithEmptyThumbnailState()
        try await testOutputCollisionsAreMarkedBeforeConversion()
        try await testOutputPlanFlagsInvalidExistingOutputAsOverwriteRisk()
        try await testOutputParentFileBlocksConversionBeforeWorkStarts()
        try testPreparingOutputRemovesInvalidExistingFileBeforeConversion()
        try testThumbnailRendererProducesBoundedPNGData()
        try testEffectiveConcurrencyRespectsMemoryAndUserLimit()
        try testClearCompletedAndRetryFailedKeepQueuePredictable()
        try testThumbnailResultOnlyAppliesToExistingMatchingQueueItem()
        try testUserFacingCopyUsesClearConversionTerms()
        try testProductPolicyDefaults()
        try testSimplifiedProductSwitches()
        print("XDRemuxAppModelTests passed")
    }

    @MainActor
    private static func testImportDiscoversHEICFilesAndDeduplicates() async throws {
        let root = try makeTempDirectory("import")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeFile(root.appendingPathComponent("a.heic"))
        try writeFile(nested.appendingPathComponent("b.HEIC"))
        try writeFile(root.appendingPathComponent("ignore.jpg"))

        let viewModel = XDRemuxViewModel()
        let added = await viewModel.importFiles(from: [root])

        try expect(added == 2, "expected two HEIC files to be imported")
        try expect(viewModel.queue.count == 2, "queue should contain imported HEIC files")
        try expect(viewModel.queue.allSatisfy { $0.status == .pending }, "new queue rows should be pending")

        let addedAgain = await viewModel.importFiles(from: [root])
        try expect(addedAgain == 0, "duplicate import should add no new rows")
        try expect(viewModel.queue.count == 2, "duplicate import should not duplicate queue rows")
    }

    @MainActor
    private static func testImportedRowsStartWithEmptyThumbnailState() async throws {
        let root = try makeTempDirectory("thumbnail-empty")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let input = root.appendingPathComponent("source.heic")
        try writeFile(input)

        let viewModel = XDRemuxViewModel()
        _ = await viewModel.importFiles(from: [input])

        guard let item = viewModel.queue.first else {
            throw TestFailure.assertion("expected imported item")
        }
        try expect(viewModel.thumbnailStatus(for: item.id) == .empty, "imported rows should start with empty thumbnail state")
    }

    @MainActor
    private static func testOutputCollisionsAreMarkedBeforeConversion() async throws {
        let root = try makeTempDirectory("collision-input")
        let out = try makeTempDirectory("collision-output")
        defer {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: out.deletingLastPathComponent())
        }

        let left = root.appendingPathComponent("left", isDirectory: true)
        let right = root.appendingPathComponent("right", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        try writeFile(left.appendingPathComponent("same.heic"))
        try writeFile(right.appendingPathComponent("same.heic"))

        let viewModel = XDRemuxViewModel()
        viewModel.config.outputDirectory = out
        _ = await viewModel.importFiles(from: [root])

        let collisionCount = viewModel.markOutputCollisionsForTesting()
        try expect(collisionCount == 2, "both colliding queue rows should be marked")
        try expect(viewModel.queue.allSatisfy { $0.status == .failed }, "colliding rows should fail before conversion")
        try expect(viewModel.queue.allSatisfy { $0.outputPlanStatus == .duplicateOutput }, "colliding rows should show duplicate output plan state")
        try expect(viewModel.queue.allSatisfy { ($0.errorMessage ?? "").contains("输出路径冲突") }, "collisions should explain the output conflict")
    }

    @MainActor
    private static func testOutputPlanFlagsInvalidExistingOutputAsOverwriteRisk() async throws {
        let root = try makeTempDirectory("overwrite-risk-input")
        let out = try makeTempDirectory("overwrite-risk-output")
        defer {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: out.deletingLastPathComponent())
        }

        let input = root.appendingPathComponent("a.heic")
        let output = out.appendingPathComponent("a.heic")
        try writeFile(input)
        try writeFile(output, bytes: 32)

        let viewModel = XDRemuxViewModel()
        viewModel.config.outputDirectory = out
        _ = await viewModel.importFiles(from: [input])
        viewModel.refreshOutputURLsForPendingItems()

        try expect(viewModel.queue.first?.outputURL == output, "output directory should map to the expected target path")
        try expect(viewModel.queue.first?.outputPlanStatus == .willOverwriteExisting, "invalid existing output should be visible as overwrite risk")
        try expect(viewModel.canStart, "overwrite risk should not block conversion because conversion can replace the target")
    }

    @MainActor
    private static func testOutputParentFileBlocksConversionBeforeWorkStarts() async throws {
        let root = try makeTempDirectory("parent-file-input")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let input = root.appendingPathComponent("a.heic")
        let outputParentFile = root.appendingPathComponent("not-a-directory")
        try writeFile(input)
        try writeFile(outputParentFile)

        let viewModel = XDRemuxViewModel()
        viewModel.config.outputDirectory = outputParentFile
        _ = await viewModel.importFiles(from: [input])

        let blockedCount = viewModel.markOutputCollisionsForTesting()
        try expect(blockedCount == 1, "parent file should block the row before conversion")
        try expect(viewModel.queue.first?.status == .failed, "blocked parent file should mark the row failed")
        try expect(viewModel.queue.first?.outputPlanStatus == .outputParentIsFile, "blocked parent file should be reflected in output plan state")
        try expect(!viewModel.canStart, "blocked rows should not keep start enabled")
    }

    @MainActor
    private static func testPreparingOutputRemovesInvalidExistingFileBeforeConversion() throws {
        let root = try makeTempDirectory("prepare-output")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let input = root.appendingPathComponent("input.heic")
        let output = root.appendingPathComponent("output.heic")
        try writeFile(input)
        try writeFile(output, bytes: 32)

        let disposition = try XDRemuxViewModel.prepareOutputForConversionForTesting(
            inputURL: input,
            outputURL: output,
            skipExisting: true
        )

        try expect(disposition == .removedExistingInvalidOutput, "invalid existing output should be removed before conversion")
        try expect(!FileManager.default.fileExists(atPath: output.path), "invalid existing output file should be gone")
    }

    @MainActor
    private static func testThumbnailRendererProducesBoundedPNGData() throws {
        let icon = URL(fileURLWithPath: "apps/macos/XDRemuxApp/Assets.xcassets/AppIcon.appiconset/icon_32x32.png")
        let data = try XDRemuxViewModel.makeThumbnailPNGDataForTesting(for: icon, maxPixelSize: 24)

        try expect(data.count > 8, "thumbnail renderer should produce image data")
        try expect(data.prefix(8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), "thumbnail renderer should produce PNG output")
    }

    @MainActor
    private static func testEffectiveConcurrencyRespectsMemoryAndUserLimit() throws {
        let viewModel = XDRemuxViewModel()
        viewModel.config.maxConcurrentJobs = 4

        let small = viewModel.effectiveConcurrencyForTesting(
            fileSizes: [10 * 1024 * 1024, 12 * 1024 * 1024],
            physicalMemory: 64 * 1024 * 1024 * 1024
        )
        try expect(small == 4, "small files should keep the configured concurrency")

        let large = viewModel.effectiveConcurrencyForTesting(
            fileSizes: [20 * 1024 * 1024 * 1024],
            physicalMemory: 16 * 1024 * 1024 * 1024
        )
        try expect(large == 1, "oversized inputs should drop concurrency to one")
    }

    @MainActor
    private static func testClearCompletedAndRetryFailedKeepQueuePredictable() throws {
        let root = URL(fileURLWithPath: "/tmp")
        let viewModel = XDRemuxViewModel()
        viewModel.queue = [
            ConversionQueueItem(inputURL: root.appendingPathComponent("ok.heic"), outputURL: root.appendingPathComponent("ok_iso.heic"), status: .converted),
            ConversionQueueItem(inputURL: root.appendingPathComponent("skip.heic"), outputURL: root.appendingPathComponent("skip_iso.heic"), status: .skippedExisting),
            ConversionQueueItem(inputURL: root.appendingPathComponent("bad.heic"), outputURL: root.appendingPathComponent("bad_iso.heic"), status: .failed, errorMessage: "boom"),
            ConversionQueueItem(inputURL: root.appendingPathComponent("todo.heic"), outputURL: root.appendingPathComponent("todo_iso.heic"), status: .pending)
        ]

        viewModel.clearCompleted()
        try expect(viewModel.queue.map(\.status) == [.failed, .pending], "clearCompleted should remove only completed and skipped rows")

        viewModel.retryFailed()
        try expect(viewModel.queue.map(\.status) == [.pending, .pending], "retryFailed should reset failed rows to pending")
        try expect(viewModel.queue.allSatisfy { $0.errorMessage == nil }, "retryFailed should clear old errors")
    }

    @MainActor
    private static func testThumbnailResultOnlyAppliesToExistingMatchingQueueItem() throws {
        let root = URL(fileURLWithPath: "/tmp")
        let originalURL = root.appendingPathComponent("original.heic")
        let changedURL = root.appendingPathComponent("changed.heic")
        let staleID = UUID()
        let currentID = UUID()
        let viewModel = XDRemuxViewModel()
        viewModel.queue = [
            ConversionQueueItem(id: currentID, inputURL: changedURL, outputURL: root.appendingPathComponent("changed_iso.heic"))
        ]

        let staleApplied = viewModel.applyThumbnailFailureForTesting(
            id: staleID,
            inputURL: originalURL,
            message: "stale"
        )
        try expect(!staleApplied, "thumbnail result for missing row should be ignored")

        let changedApplied = viewModel.applyThumbnailFailureForTesting(
            id: currentID,
            inputURL: originalURL,
            message: "wrong-url"
        )
        try expect(!changedApplied, "thumbnail result for stale input URL should be ignored")

        let currentApplied = viewModel.applyThumbnailFailureForTesting(
            id: currentID,
            inputURL: changedURL,
            message: "decode failed"
        )
        try expect(currentApplied, "thumbnail result for current row should be applied")
        try expect(viewModel.thumbnailStatus(for: currentID) == .failed("decode failed"), "current thumbnail failure should be stored")
    }

    @MainActor
    private static func testUserFacingCopyUsesClearConversionTerms() throws {
        try expect(AppStrings.addHEIC == "添加 HEIC", "add action should name the input type")
        try expect(AppStrings.startConversion == "开始转换", "primary action should describe conversion")
        try expect(AppStrings.emptyQueueTitle == "拖入或添加 ProXDR HEIC 文件", "empty state should use the ProXDR input term")
        try expect(AppStrings.statConverted == "成功", "converted statistic should read as success")
        try expect(AppStrings.statSkipped == "已跳过", "skipped statistic should be explicit")
        try expect(AppStrings.statCancelled == "已取消", "cancelled statistic should be explicit")
        try expect(AppStrings.statTotal == "总计", "total statistic should use the requested term")
        try expect(AppStrings.oppoCompatLabel == "[实验性] OPPO 相册 HDR 兼容层", "OPPO setting should be clearly marked experimental")
        try expect(AppStrings.inputProcessingSystemHelp.contains("ImageIO"), "system mode help should explain ImageIO ownership")
        try expect(AppStrings.inputProcessingHybridHelp.contains("HEVC Rext"), "hybrid mode help should explain the gain map rewrite")
        try expect(AppStrings.inputProcessingPassthroughHelp.contains("ISOBMFF box"), "passthrough mode help should explain container rebuilding")
        try expect(AppStrings.outputPlanOverwriteExisting.contains("覆盖"), "overwrite plan copy should make replacement explicit")
        try expect(AppStrings.previewUnavailable.contains("预览"), "thumbnail failure copy should name preview behavior")
    }

    @MainActor
    private static func testProductPolicyDefaults() throws {
        let config = ConversionConfig()

        try expect(config.family == .auto, "product input family should be detected automatically")
        try expect(config.inputProcessingBranch == .hybrid, "product output should use metadata-preserving remux")
        try expect(config.tmapFormat == .imageIO, "product output should use the device-validated 142-byte tmap")
        try expect(config.oppoCompatibility == .auto, "product output should preserve source HDR routing flags")
        try expect(config.oppoCameraTail == .preserve, "product output should preserve the complete source tail")
        try expect(config.oppoGalleryCompatibilityEnabled, "OPPO Gallery compatibility should default on")
        try expect(config.preservesPortraitEditingData, "portrait editing data should default to preserved")
    }

    @MainActor
    private static func testSimplifiedProductSwitches() throws {
        var config = ConversionConfig()

        config.oppoGalleryCompatibilityEnabled = false
        try expect(config.oppoCompatibility == .off, "disabling compatibility should select Hybrid high-spec encoding")
        try expect(config.oppoCameraTail == .preserve, "encoding mode must not change metadata preservation")

        config.preservesPortraitEditingData = false
        try expect(config.oppoCameraTail == .preserveWithoutPortrait, "portrait switch should select the filtered tail")
        try expect(config.oppoCompatibility == .off, "portrait switch must not change Gain Map encoding")

        config.oppoGalleryCompatibilityEnabled = true
        config.preservesPortraitEditingData = true
        try expect(config.oppoCompatibility == .auto, "enabling compatibility should restore automatic OPPO routing")
        try expect(config.oppoCameraTail == .preserve, "enabling portrait preservation should restore the byte-preserving tail")
    }
}
