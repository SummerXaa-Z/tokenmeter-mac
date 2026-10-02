import Foundation

// 模型榜 CSV 导出：纯函数生成文本，UI 层只负责选路径和写盘。
// 行序即当前排序档下的完整榜单（不只界面上的前 5），列与模型榜
// 悬停数字同管线：范围 Token 与占比来自榜单本身，近 7/30 天 Token、
// 30 天 API 等价与活跃天数来自近 30 天明细留存，参考单价复用单价小抄。
// 断流（近 30 天无明细）与缺价的格留空——留空表示「没有这个口径的
// 数字」，不是 0（与用量导出同约定）。模型名等文本含逗号/引号时按
// RFC 4180 转义。末尾附「口径」行：范围、排序与留空语义随文件自带。
enum ModelRankingCSVExport {
    struct Row {
        let rank: Int              // 1 起，调用方按当前排序给出
        let source: String         // 展示名（与榜单一致）
        let model: String
        let rangeTokens: Int       // 所选范围 Token 合计
        let sharePercent: Double   // 0...1，与榜单同源
        let weekTokens: Int?       // 近 7 天；nil = 近 30 天断流
        let monthTokens: Int?      // 近 30 天
        let monthUSD: Double?      // 近 30 天 API 等价；nil = 断流或缺价
        let activeDays: Int?       // 近 30 天活跃天数
        let priceNote: String      // 单价小抄（如 "$3 / $15 /M"）；空 = 缺价
    }

    static func makeCSV(
        rows: [Row],
        scopeTitle: String,
        sortTitle: String,
        todayKey: String = DateUtil.today()
    ) -> String {
        var lines = [[String]]()
        lines.append([
            "名次", "来源", "模型", "范围Token", "范围占比%",
            "近7天Token", "近30天Token", "近30天API等价(USD)", "近30天活跃天数", "参考单价",
        ])
        for row in rows {
            lines.append([
                String(row.rank),
                escaped(row.source),
                escaped(row.model),
                String(row.rangeTokens),
                String(Int((row.sharePercent * 100).rounded())),
                row.weekTokens.map(String.init) ?? "",
                row.monthTokens.map(String.init) ?? "",
                row.monthUSD.map { String(format: "%.2f", $0) } ?? "",
                row.activeDays.map(String.init) ?? "",
                escaped(row.priceNote),
            ])
        }
        lines.append([
            "口径",
            escaped("范围 \(scopeTitle)"),
            escaped("排序 \(sortTitle)"),
            "等价与近7天来自近30天明细留存（断流或缺价留空）",
            "导出于 \(todayKey)",
        ])
        return lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// CSV 字段转义（RFC 4180）：含逗号、引号或换行时整体加引号，
    /// 内部引号翻倍。数字与日期列不经过这里。
    static func escaped(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 名字段净化为文件名安全段：路径分隔符等不安全字符换连字符、
    /// 连续连字符（含转换来的）折叠为一个、截断超长（40 字符）；全部
    /// 不安全时返回空串，由调用方回退各自领域的通用名。Skill/模型明细
    /// 导出共用。
    static func sanitizedNameToken(_ raw: String) -> String {
        var sanitized = ""
        for ch in raw {
            let safe = (ch.isLetter || ch.isNumber || ch == "-" || ch == "_") ? ch : "-"
            if safe == "-" && sanitized.hasSuffix("-") { continue }
            sanitized.append(safe)
        }
        let trimmed = sanitized
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(40)
        return String(trimmed)
    }

    static func suggestedFilename() -> String {
        "TokenMeter-models-\(DateUtil.today()).csv"
    }
}
