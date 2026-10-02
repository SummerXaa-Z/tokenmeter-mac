import XCTest
@testable import TokenMeter

// 导出反馈文案：各导出卡保存面板点完「存储」后的行内反馈
//（「已导出 <文件名> · 时刻」），与设置页推样例反馈同款式样。
final class ExportFeedbackTests: XCTestCase {
    private func fixedTime(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testTextCarriesFilenameAndCompletionTime() {
        // 只取文件名(不含路径);时刻 HH:mm
        XCTAssertEqual(
            ExportFeedback.text(
                fileURL: URL(fileURLWithPath: "/tmp/exports/TokenMeter-usage.csv"),
                completedAt: fixedTime(2026, 10, 3, 9, 41)),
            "已导出 TokenMeter-usage.csv · 09:41")
        XCTAssertEqual(
            ExportFeedback.text(
                fileURL: URL(fileURLWithPath: "/Users/x/Downloads/TokenMeter-models-30d.csv"),
                completedAt: fixedTime(2026, 10, 3, 23, 5)),
            "已导出 TokenMeter-models-30d.csv · 23:05")
    }

    func testTextKeepsTimestampRollingOverHour() {
        // 跨小时/深夜时刻照常两位显示,不出现 24:xx
        XCTAssertEqual(
            ExportFeedback.text(
                fileURL: URL(fileURLWithPath: "/tmp/a.csv"),
                completedAt: fixedTime(2026, 10, 3, 0, 7)),
            "已导出 a.csv · 00:07")
    }
}
