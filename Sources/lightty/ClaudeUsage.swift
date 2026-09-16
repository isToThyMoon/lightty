import Foundation

/// 一样东西被用过多少次、最近一次是什么时候。
struct UsageRecord: Equatable, Sendable {
    let count: Int
    let lastUsed: Date?

    /// 「Claude Code 用过 7 次 · 3 天前」。次数为 0 时不提时间——那个时间戳记的是
    /// 上次把它加载进来，不是上次用它，摆出来会读成「用过，就在 3 天前」。
    func summary(localize: (String) -> String) -> String {
        guard count > 0 else { return localize("Never used by Claude Code") }
        let times = String(format: localize("Used %d times by Claude Code"), count)
        guard let lastUsed else { return times }
        return times + " · " + RelativeTime.text(lastUsed, localize: localize)
    }
}

/// 相对时间的说法，界面上好几处都要用同一套。
enum RelativeTime {
    static func text(_ date: Date, localize: (String) -> String) -> String {
        let seconds = max(0, -date.timeIntervalSinceNow)
        if seconds < 60 { return localize("just now") }
        if seconds < 3_600 { return String(format: localize("%d min ago"), Int(seconds / 60)) }
        if seconds < 86_400 { return String(format: localize("%d hr ago"), Int(seconds / 3_600)) }
        if seconds < 604_800 { return String(format: localize("%d days ago"), Int(seconds / 86_400)) }
        let formatter = DateFormatter()
        formatter.dateFormat = localize("MMM d")
        return formatter.string(from: date)
    }
}

/// Claude Code 记在 `~/.claude.json` 里的使用计数：`pluginUsage` 按 `name@marketplace`，
/// `skillUsage` 按技能名。Codex 不记这个，两边并不对称——凡是展示它的地方都要
/// 说清这是 Claude Code 的统计，否则一个 Codex 技能会读成「从没用过」。
enum ClaudeUsage {
    struct Snapshot: Sendable {
        var plugins: [String: UsageRecord] = [:]
        /// 键是技能名，不带来源：Claude Code 就是按名字统计的，
        /// 同名的两份安装因此共用一条记录。
        var skills: [String: UsageRecord] = [:]
    }

    static func read(home: URL) -> Snapshot {
        let url = home.appendingPathComponent(".claude.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Snapshot()
        }
        return Snapshot(plugins: records(in: json["pluginUsage"]), skills: records(in: json["skillUsage"]))
    }

    private static func records(in value: Any?) -> [String: UsageRecord] {
        guard let entries = value as? [String: Any] else { return [:] }
        return entries.reduce(into: [:]) { result, entry in
            guard let fields = entry.value as? [String: Any] else { return }
            let count = (fields["usageCount"] as? NSNumber)?.intValue ?? 0
            // 毫秒时间戳。缺了就只报次数，不编一个时间出来。
            let milliseconds = (fields["lastUsedAt"] as? NSNumber)?.doubleValue
            result[entry.key] = UsageRecord(
                count: count,
                lastUsed: milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) })
        }
    }
}
