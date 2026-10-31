import XCTest
@testable import XDRemuxModel

final class FlutterCheckpointTests: XCTestCase {
    /// Lines as `checkpoint_model.dart` writes them (Dart local time, microseconds).
    let flutterJSONL = """
    {"type":"header","configHash":"1a2b3c4d","totalJobs":3,"startedAt":"2026-10-30T21:00:00.123456","appVersion":"0.4.6"}
    {"type":"item","inputPath":"/Users/me/Pictures/a.heic","outputPath":"/Users/me/Pictures/a_iso.heic","status":"converted","inputSize":10,"inputMtimeMs":1,"finishedAt":"2026-10-30T21:01:00.000000","captureModeKey":"master","captureModeFolderName":"大师模式","hdrKind":"uhdr","family":"x7","motionPhotoMode":"livePhotoPair","motionPhoto":{"durationMs":3000}}
    {"type":"item","inputPath":"/Users/me/Pictures/b.heic","outputPath":"/Users/me/Pictures/b_iso.heic","status":"skippedPolicy","inputSize":0,"inputMtimeMs":0,"policyReason":"华为 HDR 原生兼容 Apple Photos，无需转换","huaweiHdr":true,"motionPhotoMode":"still"}
    {"type":"item","inputPath":"/Users/me/Pictures/c.jpg","outputPath":"/Users/me/Pictures/c_iso.heic","status":"failed","inputSize":0,"inputMtimeMs":0,"error":"boom","motionPhotoMode":"livePhotoPair"}
    not json at all
    """

    func testParsesFlutterLinesAndSkipsGarbage() throws {
        let cp = try XCTUnwrap(FlutterCheckpoint.parse(jsonl: flutterJSONL))
        XCTAssertEqual(cp.header.configHash, "1a2b3c4d")
        XCTAssertEqual(cp.header.totalJobs, 3)
        XCTAssertEqual(cp.items.count, 3)
        XCTAssertEqual(cp.items[0].status, .converted)
        XCTAssertEqual(cp.items[0].captureModeFolderName, "大师模式")
        XCTAssertNotNil(cp.items[0].finishedAt)
        XCTAssertEqual(cp.items[1].huaweiHdr, true)
        XCTAssertEqual(cp.items[2].error, "boom")
        XCTAssertNil(FlutterCheckpoint.parse(jsonl: ""))
        XCTAssertNil(FlutterCheckpoint.parse(jsonl: "{\"type\":\"item\"}"))
    }

    func testRoundTripThroughJSONL() throws {
        let cp = try XCTUnwrap(FlutterCheckpoint.parse(jsonl: flutterJSONL))
        let text = cp.jsonl()
        XCTAssertTrue(text.hasPrefix("{\"appVersion\":\"0.4.6\",\"configHash\":\"1a2b3c4d\""))
        XCTAssertTrue(text.contains("\"type\":\"header\""))
        let again = try XCTUnwrap(FlutterCheckpoint.parse(jsonl: text))
        XCTAssertEqual(again.items.map(\.inputPath), cp.items.map(\.inputPath))
        XCTAssertEqual(again.items.map(\.status), cp.items.map(\.status))
        XCTAssertEqual(again.items[0].captureModeFolderName, "大师模式")
    }

    func testJournalRecordsMapStatuses() throws {
        let cp = try XCTUnwrap(FlutterCheckpoint.parse(jsonl: flutterJSONL))
        let records = cp.journalRecords()
        XCTAssertEqual(records.map(\.status), [.succeeded, .pending, .failed])
        XCTAssertEqual(records[0].outputPath, "/Users/me/Pictures/a_iso.heic")
        XCTAssertEqual(records[0].motionMode, .livePhotoPair)
        XCTAssertEqual(records[0].sourceName, "a.heic")
        XCTAssertEqual(records[1].motionMode, .still)
        XCTAssertEqual(records[2].errorMessage, "boom")
    }

    func testExportFromJournal() {
        let journal = QueueJournal(records: [
            .init(sourceName: "a.heic", inputPath: "~/Library/Caches/XDRemux/inputs/UUID-a.heic", status: .succeeded,
                  outputPath: "~/Documents/outputs/a_iso.heic", outcome: ConversionOutcome(success: true, family: "x7"), motionMode: .still),
            .init(sourceName: "b.heic", inputPath: "/abs/b.heic", status: .running),
            .init(sourceName: "c.heic", inputPath: "/abs/c.heic", status: .failed, errorMessage: "nope"),
        ])
        let cp = FlutterCheckpoint.from(journal: journal, config: ConversionConfig(), appVersion: "0.1.0") {
            QueueJournal.absolute($0, home: "/home")
        }
        XCTAssertEqual(cp.header.totalJobs, 3)
        XCTAssertEqual(cp.header.configHash, FlutterCheckpoint.configHash(ConversionConfig()))
        XCTAssertEqual(cp.items.map(\.status), [.converted, .pending, .failed])
        XCTAssertEqual(cp.items[0].inputPath, "/home/Library/Caches/XDRemux/inputs/UUID-a.heic")
        XCTAssertEqual(cp.items[0].outputPath, "/home/Documents/outputs/a_iso.heic")
        XCTAssertEqual(cp.items[0].motionPhotoMode, "still")
        XCTAssertEqual(cp.items[2].error, "nope")
        XCTAssertNotNil(FlutterCheckpoint.parse(jsonl: cp.jsonl()))
    }

    func testConfigHashIsStableAndSensitive() {
        var a = ConversionConfig(), b = ConversionConfig()
        XCTAssertEqual(FlutterCheckpoint.configHash(a), FlutterCheckpoint.configHash(b))
        b.outputMode = .apple
        XCTAssertNotEqual(FlutterCheckpoint.configHash(a), FlutterCheckpoint.configHash(b))
        a.fileNameSuffix = "_hdr"
        XCTAssertNotEqual(FlutterCheckpoint.configHash(a), FlutterCheckpoint.configHash(ConversionConfig()))
    }
}
