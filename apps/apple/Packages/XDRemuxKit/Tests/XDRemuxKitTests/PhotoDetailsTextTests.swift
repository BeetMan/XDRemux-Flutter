import Foundation
import XCTest
@testable import XDRemuxKit

final class PhotoDetailsTextTests: XCTestCase {
    private func details(_ json: String) throws -> PhotoDetails {
        try JSONDecoder().decode(PhotoDetails.self, from: Data(json.utf8))
    }

    func testMegapixelsRoundsByMagnitude() throws {
        XCTAssertEqual(try details(#"{"success":true,"width":8192,"height":7168}"#).megapixelsText, "59 MP")
        XCTAssertEqual(try details(#"{"success":true,"width":3244,"height":5444}"#).megapixelsText, "18 MP")
        XCTAssertEqual(try details(#"{"success":true,"width":1920,"height":1080}"#).megapixelsText, "2.1 MP")
        XCTAssertNil(try details(#"{"success":true,"width":0,"height":1080}"#).megapixelsText)
        XCTAssertNil(try details(#"{"success":true}"#).megapixelsText)
    }

    func testProgressFractionIsBandedByStage() {
        func f(_ stage: UInt32, _ cur: UInt32 = 0, _ total: UInt32 = 0) -> Double {
            ConversionProgress(stage: stage, current: cur, total: total).fraction
        }
        XCTAssertEqual(f(0), 0)
        XCTAssertLessThan(f(1), f(2))
        XCTAssertLessThan(f(2), f(3, 0, 48))
        XCTAssertLessThan(f(3, 0, 48), f(3, 24, 48))
        XCTAssertLessThan(f(3, 48, 48), f(4))
        XCTAssertLessThan(f(4), 1)
        XCTAssertEqual(ConversionProgress.Phase(fraction: f(1)), .extract)
        XCTAssertEqual(ConversionProgress.Phase(fraction: f(2)), .decode)
        XCTAssertEqual(ConversionProgress.Phase(fraction: f(3, 10, 48)), .encode)
        XCTAssertEqual(ConversionProgress.Phase(fraction: f(4)), .assemble)
    }
}
