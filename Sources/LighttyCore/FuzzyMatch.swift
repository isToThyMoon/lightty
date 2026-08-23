import Foundation

/// 贪心子序列模糊匹配，用于任务面板搜索排序
public enum FuzzyMatch {
    /// 大小写不敏感。pattern 不是 candidate 的子序列时返回 nil。
    /// 分数越高排序越靠前：连续命中每处 +2 奖励，首命中越靠前分越高。
    /// 空 pattern 视为全匹配（0 分）。
    public static func score(pattern: String, in candidate: String) -> Int? {
        let p = Array(pattern.lowercased())
        guard !p.isEmpty else { return 0 }
        let c = Array(candidate.lowercased())

        var score = 0
        var pi = 0
        var lastMatch = -2
        var firstMatch = -1
        for (i, ch) in c.enumerated() {
            guard pi < p.count else { break }
            if ch == p[pi] {
                score += 1
                if i == lastMatch + 1 { score += 2 } // 连续命中奖励
                if firstMatch < 0 { firstMatch = i }
                lastMatch = i
                pi += 1
            }
        }
        guard pi == p.count else { return nil }
        return score - firstMatch // 靠前奖励：首命中位置作为罚分
    }
}
