import XCTest
@testable import XDRemuxTransfer

/// Zips are made with the system `zip` (stored and deflated), as a stand-in
/// for the Flutter app's stored `.pvt.zip`.
final class LivePhotoZipTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("xdremux-pvtzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeBundle(_ name: String, files: [String: Data]) throws -> URL {
        let bundle = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for (file, data) in files { try data.write(to: bundle.appendingPathComponent(file)) }
        return bundle
    }

    private func zip(_ bundle: URL, store: Bool) throws -> URL {
        let out = base.appendingPathComponent(bundle.lastPathComponent + ".zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = bundle.deletingLastPathComponent()
        process.arguments = ["-q", "-r"] + (store ? ["-0"] : []) + [out.path, bundle.lastPathComponent]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return out
    }

    private var still: Data { Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }) }
    private var movie: Data { Data(repeating: 0x42, count: 150_000) + Data("tail".utf8) }

    func testUnpackStoredAndDeflated() throws {
        for store in [true, false] {
            let dir = base.appendingPathComponent(store ? "stored" : "deflated", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let bundle = try makeBundle("IMG_0001.pvt", files: ["IMG_0001.HEIC": still, "IMG_0001.mov": movie,
                                                                "metadata.plist": Data("<plist/>".utf8)])
            let zipURL = try zip(bundle, store: store)
            let archive = try ZipArchive(url: zipURL)
            XCTAssertTrue(archive.entries.contains { $0.name == "IMG_0001.pvt/IMG_0001.HEIC" })

            XCTAssertTrue(LivePhotoZip.isLivePhotoZip("IMG_0001.pvt.zip"))
            let parts = try LivePhotoZip.unpack(zipURL, name: "IMG_0001.pvt.zip", into: dir)
            XCTAssertEqual(parts.still.lastPathComponent, "IMG_0001.HEIC")
            XCTAssertEqual(parts.movie.lastPathComponent, "IMG_0001.mov")
            XCTAssertEqual(try Data(contentsOf: parts.still), still)
            XCTAssertEqual(try Data(contentsOf: parts.movie), movie)
            XCTAssertThrowsError(try LivePhotoZip.unpack(zipURL, name: "IMG_0001.pvt.zip", into: dir)) {
                XCTAssertEqual($0 as? LivePhotoZip.Failure, .alreadyExists)
            }
            let preview = try LivePhotoZip.extractStill(zipURL, into: dir)
            XCTAssertEqual(try Data(contentsOf: preview), still)
            try FileManager.default.removeItem(at: bundle)
            try FileManager.default.removeItem(at: zipURL)
        }
    }

    func testRejectsBundleWithoutMovie() throws {
        let bundle = try makeBundle("IMG_0002.pvt", files: ["IMG_0002.HEIC": still])
        let zipURL = try zip(bundle, store: true)
        let out = base.appendingPathComponent("o", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        XCTAssertThrowsError(try LivePhotoZip.unpack(zipURL, name: "IMG_0002.pvt.zip", into: out)) {
            XCTAssertEqual($0 as? LivePhotoZip.Failure, .invalidLivePhoto)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("IMG_0002.pvt").path))
    }

    func testRejectsEntriesOutsideBundle() throws {
        let bundle = try makeBundle("IMG_0003.pvt", files: ["IMG_0003.HEIC": still, "IMG_0003.mov": movie])
        // A second top-level entry next to the bundle.
        try Data("x".utf8).write(to: base.appendingPathComponent("stray.txt"))
        let out = base.appendingPathComponent("IMG_0003.pvt.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = base
        process.arguments = ["-q", "-r", out.path, bundle.lastPathComponent, "stray.txt"]
        try process.run(); process.waitUntilExit()
        XCTAssertThrowsError(try LivePhotoZip.unpack(out, name: "IMG_0003.pvt.zip", into: base.appendingPathComponent("o")))
    }

    func testNotAZip() {
        XCTAssertThrowsError(try ZipArchive(data: Data(repeating: 0, count: 100))) {
            XCTAssertEqual($0 as? ZipArchive.Failure, .notZip)
        }
    }
}
