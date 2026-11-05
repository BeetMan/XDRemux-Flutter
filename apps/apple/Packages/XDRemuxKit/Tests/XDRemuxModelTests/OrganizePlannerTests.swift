import XCTest
@testable import XDRemuxModel

final class OrganizePlannerTests: XCTestCase {
    let root = URL(fileURLWithPath: "/out")
    let layout = OrganizePlanner.Layout(stillFolder: "静态照片", liveFolder: "实况照片")

    func testLayoutPutsModesUnderStillOrLive() {
        let items = [
            OrganizePlanner.Item(sourceURL: URL(fileURLWithPath: "/in/a.heic"), folderName: "大师模式"),
            OrganizePlanner.Item(sourceURL: URL(fileURLWithPath: "/in/b.jpg"), folderName: "人像",
                                 pairedVideoURL: URL(fileURLWithPath: "/in/b.mov")),
            OrganizePlanner.Item(sourceURL: URL(fileURLWithPath: "/in/c.heic"), folderName: nil),
        ]
        let plan = OrganizePlanner.plan(items, root: root, layout: layout) { _ in false }
        XCTAssertEqual(plan[0].destination.path, "/out/静态照片/大师模式/a.heic")
        XCTAssertEqual(plan[1].destination.path, "/out/实况照片/人像/b.jpg")
        XCTAssertEqual(plan[1].videoDestination?.path, "/out/实况照片/人像/b.mov")
        XCTAssertEqual(plan[2].destination.path, "/out/静态照片/c.heic")
        XCTAssertFalse(plan.contains { $0.isDuplicate })
    }

    func testCollisionsWithPlannedAndExistingFiles() {
        let items = [
            OrganizePlanner.Item(sourceURL: URL(fileURLWithPath: "/in/x/a.heic"), folderName: "夜景"),
            OrganizePlanner.Item(sourceURL: URL(fileURLWithPath: "/in/y/A.HEIC"), folderName: "夜景"),
        ]
        // The disk is case-insensitive (APFS default), so the fake is too.
        let existing: Set<String> = ["/out/静态照片/夜景/a (2).heic"]
        let plan = OrganizePlanner.plan(items, root: root, layout: layout) { existing.contains($0.path.lowercased()) }
        XCTAssertEqual(plan[0].destination.path, "/out/静态照片/夜景/a.heic")
        // "A.HEIC" collides case-insensitively with the planned a.heic, and "(2)" exists on disk.
        XCTAssertEqual(plan[1].destination.path, "/out/静态照片/夜景/A (3).HEIC")
    }

    func testOrganizingIntoOwnFolderIsDuplicateNotCollision() {
        let source = URL(fileURLWithPath: "/out/静态照片/夜景/a.heic")
        let plan = OrganizePlanner.plan([.init(sourceURL: source, folderName: "夜景")], root: root, layout: layout) {
            $0.path == source.path
        }
        XCTAssertEqual(plan[0].destination.path, source.path)
        XCTAssertTrue(plan[0].isDuplicate)
    }

    func testExecuteCopiesPairsSkipsDuplicatesAndReportsFailures() {
        let ok = OrganizePlanner.Item(sourceURL: URL(fileURLWithPath: "/in/b.jpg"), folderName: "人像",
                                      pairedVideoURL: URL(fileURLWithPath: "/in/b.mov"))
        let dup = OrganizePlanner.Item(sourceURL: URL(fileURLWithPath: "/out/静态照片/c.heic"))
        let bad = OrganizePlanner.Item(sourceURL: URL(fileURLWithPath: "/in/bad.heic"))
        let plan = OrganizePlanner.plan([ok, dup, bad], root: root, layout: layout) { $0.path == dup.sourceURL.path }
        var copies: [String] = []
        let outcome = OrganizePlanner.execute(plan) { from, to in
            if from.lastPathComponent == "bad.heic" { throw CocoaError(.fileWriteNoPermission) }
            copies.append("\(from.lastPathComponent)->\(to.path)")
        }
        XCTAssertEqual(copies, ["b.jpg->/out/实况照片/人像/b.jpg", "b.mov->/out/实况照片/人像/b.mov"])
        XCTAssertEqual(outcome.copied, 1)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(outcome.failed.map(\.0.lastPathComponent), ["bad.heic"])
    }

    /// Real files in a temp dir: the pair lands together under the live
    /// folder, a second run sees everything as duplicates.
    func testEndToEndOnDisk() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("organize-\(UUID().uuidString)")
        let input = tmp.appendingPathComponent("in"), output = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("still".utf8).write(to: input.appendingPathComponent("p.heic"))
        try Data("video".utf8).write(to: input.appendingPathComponent("p.mov"))
        let item = OrganizePlanner.Item(sourceURL: input.appendingPathComponent("p.heic"), folderName: "人像",
                                        pairedVideoURL: input.appendingPathComponent("p.mov"))
        let copy: (URL, URL) throws -> Void = { from, to in
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: from, to: to)
        }
        let exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
        let first = OrganizePlanner.execute(OrganizePlanner.plan([item], root: output, layout: layout, exists: exists), copy: copy)
        XCTAssertEqual(first.copied, 1)
        XCTAssertTrue(exists(output.appendingPathComponent("实况照片/人像/p.heic")))
        XCTAssertTrue(exists(output.appendingPathComponent("实况照片/人像/p.mov")))
        // Organizing the organized copy into the same root: duplicate, no "(2)".
        let organized = OrganizePlanner.Item(sourceURL: output.appendingPathComponent("实况照片/人像/p.heic"), folderName: "人像",
                                             pairedVideoURL: output.appendingPathComponent("实况照片/人像/p.mov"))
        let second = OrganizePlanner.plan([organized], root: output, layout: layout, exists: exists)
        XCTAssertTrue(second[0].isDuplicate)
        XCTAssertEqual(OrganizePlanner.execute(second, copy: copy).skipped, 1)
        // The original again: collides with the copy on disk → "(2)".
        let again = OrganizePlanner.plan([item], root: output, layout: layout, exists: exists)
        XCTAssertEqual(again[0].destination.lastPathComponent, "p (2).heic")
        XCTAssertEqual(again[0].videoDestination?.lastPathComponent, "p (2).mov")
    }
}
