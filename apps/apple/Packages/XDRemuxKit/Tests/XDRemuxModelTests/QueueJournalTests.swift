import Foundation
import XCTest
@testable import XDRemuxModel

final class QueueJournalTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRoundTrip() throws {
        let store = QueueJournalStore(fileURL: dir.appendingPathComponent("queue.json"))
        XCTAssertNil(try store.load())
        var journal = QueueJournal()
        journal.records.append(.init(sourceName: "a.heic", inputPath: "/in/a.heic"))
        journal.records.append(.init(sourceName: "b.heic", inputPath: "/in/b.heic", status: .succeeded,
                                     outputPath: "/out/b_iso.heic",
                                     outcome: ConversionOutcome(success: true, mode: "lhdr", family: "x6", edrScale: 1.2, gainMapMax: 0.3),
                                     config: ConversionConfig(), savedToPhotos: true))
        try store.save(journal)
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.records.count, 2)
        XCTAssertEqual(loaded.records[1].outcome?.family, "x6")
        XCTAssertTrue(loaded.records[1].savedToPhotos)
        XCTAssertEqual(loaded.records[1].config, ConversionConfig())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.appendingPathExtension("tmp").path))
    }

    func testSaveReplacesExisting() throws {
        let store = QueueJournalStore(fileURL: dir.appendingPathComponent("queue.json"))
        try store.save(QueueJournal(records: [.init(sourceName: "a", inputPath: "/a")]))
        try store.save(QueueJournal(records: []))
        XCTAssertEqual(try store.load()?.records.count, 0)
    }

    func testMalformedFileIsQuarantined() throws {
        let store = QueueJournalStore(fileURL: dir.appendingPathComponent("queue.json"))
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertNil(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(leftovers.contains { $0.hasPrefix("queue.corrupt-") }, "\(leftovers)")
    }

    func testNewerSchemaIsRefused() throws {
        let store = QueueJournalStore(fileURL: dir.appendingPathComponent("queue.json"))
        try Data(#"{"schema": 99, "records": []}"#.utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? QueueJournalError, .unsupportedSchema(99))
        }
    }

    func testRestoreRules() {
        let journal = QueueJournal(records: [
            .init(sourceName: "running", inputPath: "/in/r", status: .running),
            .init(sourceName: "done-ok", inputPath: "/in/d1", status: .succeeded, outputPath: "/out/d1"),
            .init(sourceName: "done-lost-output", inputPath: "/in/d2", status: .succeeded, outputPath: "/out/d2"),
            .init(sourceName: "lost-input", inputPath: "/in/missing", status: .pending),
            .init(sourceName: "failed", inputPath: "/in/f", status: .failed, errorMessage: "x"),
        ])
        let existing: Set<String> = ["/in/r", "/in/d1", "/out/d1", "/in/d2", "/in/f"]
        let restored = journal.restored { existing.contains($0) }
        let byName = Dictionary(uniqueKeysWithValues: restored.records.map { ($0.sourceName, $0) })
        XCTAssertEqual(byName["running"]?.status, .pending)
        XCTAssertEqual(byName["done-ok"]?.status, .succeeded)
        XCTAssertEqual(byName["done-lost-output"]?.status, .failed)
        XCTAssertNil(byName["done-lost-output"]?.outputPath)
        XCTAssertEqual(byName["lost-input"]?.status, .failed)
        XCTAssertEqual(byName["failed"]?.errorMessage, "x")
    }
}
