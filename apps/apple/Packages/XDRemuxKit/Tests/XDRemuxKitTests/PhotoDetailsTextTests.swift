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
}
