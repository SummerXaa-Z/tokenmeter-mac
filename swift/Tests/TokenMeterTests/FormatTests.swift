import XCTest
@testable import TokenMeter

final class FormatTests: XCTestCase {
    func testTokenAbbreviationsPromoteToBillions() {
        XCTAssertEqual(Fmt.tokensShort(999_499_999), "999M")
        XCTAssertEqual(Fmt.tokensShort(999_500_000), "1.0B")
        XCTAssertEqual(Fmt.tokensShort(1_200_000_000), "1.2B")
        XCTAssertEqual(Fmt.tokensShort(100_000_000_000), "100B")
    }

    func testTokenAbbreviationsPreserveSmallerUnits() {
        XCTAssertEqual(Fmt.tokensShort(999), "999")
        XCTAssertEqual(Fmt.tokensShort(2_609), "2.6K")
        XCTAssertEqual(Fmt.tokensShort(1_000_000), "1.0M")
        XCTAssertEqual(Fmt.tokensShort(380_000_000), "380M")
    }
}
