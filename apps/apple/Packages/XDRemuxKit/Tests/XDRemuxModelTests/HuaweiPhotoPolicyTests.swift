import XCTest
@testable import XDRemuxModel

final class HuaweiPhotoPolicyTests: XCTestCase {
    func testPlainHuaweiHdrIsSkipped() {
        XCTAssertEqual(HuaweiPhotoPolicy.admission(huaweiHdr: true, portraitReady: false, stylesRequested: false),
                       .skipped(reason: HuaweiPhotoPolicy.skipReason))
    }

    func testStylesPortraitOrMotionAdmit() {
        XCTAssertEqual(HuaweiPhotoPolicy.admission(huaweiHdr: true, portraitReady: false, stylesRequested: true), .admitted)
        XCTAssertEqual(HuaweiPhotoPolicy.admission(huaweiHdr: true, portraitReady: true, stylesRequested: false), .admitted)
        XCTAssertEqual(HuaweiPhotoPolicy.admission(huaweiHdr: true, portraitReady: false, stylesRequested: false, motionPhoto: true), .admitted)
    }

    func testNonHuaweiIsNeverTouched() {
        XCTAssertEqual(HuaweiPhotoPolicy.admission(huaweiHdr: false, portraitReady: false, stylesRequested: false), .admitted)
        XCTAssertEqual(HuaweiPhotoPolicy.admission(nil, config: ConversionConfig()), .admitted)
    }

    func testConfigConvenienceFollowsStylesToggles() {
        let info = HuaweiPhotoInfo(isHdr: true)
        var config = ConversionConfig()
        XCTAssertEqual(HuaweiPhotoPolicy.admission(info, config: config), .skipped(reason: HuaweiPhotoPolicy.skipReason))
        config.applePhotographicStyles3 = true
        XCTAssertEqual(HuaweiPhotoPolicy.admission(info, config: config), .admitted)
    }
}
