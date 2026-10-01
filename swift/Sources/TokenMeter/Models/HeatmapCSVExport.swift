import Foundation

// 热力图 CSV 导出：纯函数生成文本，UI 层只负责选路径和写盘。
// 行序即热力图当前窗口（粒度/窗口/翻页与界面所见完全一致）：日档逐日
// 一行、周档逐周一行（桶为该周周一）、月档逐月一行。Token 报原始整数
// （非界面上的 M 缩写）；窗口内无量的行照列——Token 0 是真实零，与
// 格子的空白档对应。API 等价与悬停同口径（按用量当日生效价逐日重算、
// 缺价不计），无金额留空——留空表示「没有这个口径的数字」，不是 0。
// 末尾附「口径」行：粒度、窗口与金额语义随文件自带。桶都是日期/数字，
// 仅口径行的说明文本可能含半角逗号，照 RFC 4180 转义。
enum HeatmapCSVExport {
    /// 行粒度：决定表头列名与桶的含义，与热力图卡的粒度档一一对应。
    enum Granularity {
        case day
        case week
        case month

        var title: String {
            switch self {
            case .day: return "日"
            case .week: return "周"
            case .month: return "月"
            }
        }

        var bucketTitle: String {
            switch self {
            case .day: return "日期"
            case .week: return "周(周一)"
            case .month: return "月份"
            }
        }
    }

    struct Row {
        let bucket: String     // 日=yyyy-MM-dd；周=该周周一；月=yyyy-MM
        let weekday: Int?      // 仅日档：Calendar weekday，1=周日 ... 7=周六
        let tokens: Int        // 桶内合计；0 是真实零（窗口内无用量）
        let usd: Double?       // 桶内 API 等价；nil = 无计价金额
    }

    static func makeCSV(
        rows: [Row],
        granularity: Granularity,
        windowText: String,
        todayKey: String = DateUtil.today()
    ) -> String {
        var lines = [[String]]()
        if granularity == .day {
            lines.append(["日期", "星期", "Token", "API等价(USD)"])
        } else {
            lines.append([granularity.bucketTitle, "Token", "API等价(USD)"])
        }
        for row in rows {
            let usd = row.usd.map { String(format: "%.2f", $0) } ?? ""
            if granularity == .day {
                lines.append([
                    row.bucket,
                    Self.weekdayLabel(row.weekday),
                    String(row.tokens),
                    usd,
                ])
            } else {
                lines.append([row.bucket, String(row.tokens), usd])
            }
        }
        lines.append([
            "口径",
            escaped("粒度 \(granularity.title)"),
            escaped("窗口 \(windowText)"),
            "Token为本地按天历史合计（平台账户不计）",
            "API等价按用量当日生效价重算（缺价不计、无金额留空）",
            "导出于 \(todayKey)",
        ])
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// Calendar weekday（1=周日 ... 7=周六）→ 一到日的单字；与周内节律
    /// 同一套标签。nil（周/月档）给空串保持列对齐。
    static func weekdayLabel(_ weekday: Int?) -> String {
        guard let weekday, (1...7).contains(weekday) else { return "" }
        return ["日", "一", "二", "三", "四", "五", "六"][weekday - 1]
    }

    /// CSV 字段转义（RFC 4180），与模型榜导出同一实现语义。
    static func escaped(_ field: String) -> String {
        ModelRankingCSVExport.escaped(field)
    }

    static func suggestedFilename() -> String {
        "TokenMeter-heatmap-\(DateUtil.today()).csv"
    }
}
