import XCTest
@testable import TokenMeter

final class FormatTests: XCTestCase {
    func testTokenAbbreviationsPromoteToBillions() {
        XCTAssertEqual(Fmt.tokensShort(999_499_999), "999M")
        XCTAssertEqual(Fmt.tokensShort(999_500_000), "1B")
        XCTAssertEqual(Fmt.tokensShort(1_200_000_000), "1.2B")
        XCTAssertEqual(Fmt.tokensShort(100_000_000_000), "100B")
    }

    func testTokenAbbreviationsPreserveSmallerUnits() {
        XCTAssertEqual(Fmt.tokensShort(999), "999")
        XCTAssertEqual(Fmt.tokensShort(2_609), "2.6K")
        XCTAssertEqual(Fmt.tokensShort(1_000_000), "1M")
        XCTAssertEqual(Fmt.tokensShort(25_000_000), "25M")
        XCTAssertEqual(Fmt.tokensShort(380_000_000), "380M")
    }

    func testTokenAbbreviationsPromoteThousandsToMillions() {
        // 与 M→B 同一语义：K 四舍五入到 1000 时升为 M，避免 "1000K" 边界值
        XCTAssertEqual(Fmt.tokensShort(999_449), "999.4K")
        XCTAssertEqual(Fmt.tokensShort(999_500), "1M")
        XCTAssertEqual(Fmt.tokensShort(999_950), "1M")
    }
}
