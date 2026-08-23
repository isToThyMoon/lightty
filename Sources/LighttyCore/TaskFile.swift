import Foundation

/// 任务状态，取值集合由 docs/task-format.md 固定
public enum TaskStatus: String, CaseIterable, Equatable {
    case active
    case stuck
    case done
}

/// 关联会话条目，序列化为 `<tool>:<session-id>`
public struct TaskSession: Equatable, Hashable {
    public var tool: String
    public var id: String

    public init(tool: String, id: String) {
        self.tool = tool
        self.id = id
    }
}

/// 解析错误：line 为 1-based 文件行号
public struct TaskParseError: Error, Equatable, CustomStringConvertible {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }

    public var description: String { "第 \(line) 行: \(message)" }
}

/// 单个任务文件的内存表示。格式规范见 docs/task-format.md。
public struct TaskFile: Equatable {
    public var name: String
    public var status: TaskStatus
    public var cwd: String
    public var tool: String?
    public var created: Date
    public var updated: Date
    public var sessions: [TaskSession]
    /// 未知键的原始行（不含换行符），保序保真，写回时原样输出
    public var unknownLines: [String]
    /// 正文，读写字节原样保留（包括结尾换行有无）；UTF-8 合法字符串可无损往返
    public var body: String

    public init(
        name: String,
        status: TaskStatus,
        cwd: String,
        tool: String? = nil,
        created: Date,
        updated: Date,
        sessions: [TaskSession] = [],
        unknownLines: [String] = [],
        body: String = ""
    ) {
        self.name = name
        self.status = status
        self.cwd = cwd
        self.tool = tool
        self.created = created
        self.updated = updated
        self.sessions = sessions
        self.unknownLines = unknownLines
        self.body = body
    }

    // MARK: - 解析

    public static func parse(_ data: Data) throws -> TaskFile {
        let bytes = [UInt8](data)
        let newline: UInt8 = 0x0A
        // 首行必须是 "---\n"
        guard bytes.count >= 4, bytes[0] == 0x2D, bytes[1] == 0x2D, bytes[2] == 0x2D, bytes[3] == newline else {
            throw TaskParseError(line: 1, message: "文件必须以 ---\\n 开头")
        }

        // 逐行扫描 frontmatter，找到单独成行的 "---" 为止；正文按字节切出
        var fmLines: [(line: Int, text: String)] = []
        var lineNo = 1
        var lineStart = 4
        var closingLine: Int? = nil
        var bodyBytes = Data()
        var i = 4
        while true {
            let atEnd = i == bytes.count
            if atEnd || bytes[i] == newline {
                if atEnd && lineStart == i { break } // 文件恰以换行结束，无残行
                let chunk = bytes[lineStart..<i]
                guard let text = String(bytes: chunk, encoding: .utf8) else {
                    throw TaskParseError(line: lineNo + 1, message: "frontmatter 不是合法 UTF-8")
                }
                lineNo += 1
                if text == "---" {
                    closingLine = lineNo
                    if !atEnd {
                        bodyBytes = Data(bytes[(i + 1)...])
                    }
                    break
                }
                if atEnd { break } // 末尾残行不是闭合行
                fmLines.append((lineNo, text))
                lineStart = i + 1
            }
            if atEnd { break }
            i += 1
        }
        guard let closingLine else {
            throw TaskParseError(line: max(lineNo, 1), message: "frontmatter 未用 --- 闭合")
        }
        guard let body = String(data: bodyBytes, encoding: .utf8) else {
            throw TaskParseError(line: closingLine, message: "正文不是合法 UTF-8")
        }

        // 逐行解析键值
        var name: String?
        var status: TaskStatus?
        var cwd: String?
        var tool: String?
        var created: Date?
        var updated: Date?
        var sessions: [TaskSession] = []
        var inSessions = false
        var unknownLines: [String] = []
        var seenKeys = Set<String>()

        for (line, text) in fmLines {
            if text.hasPrefix("  - ") {
                guard inSessions else {
                    throw TaskParseError(line: line, message: "列表条目只允许出现在 sessions: 块内")
                }
                let entry = text.dropFirst(4)
                guard let colon = entry.firstIndex(of: ":") else {
                    throw TaskParseError(line: line, message: "会话条目缺少 : 分隔")
                }
                let tool = String(entry[..<colon])
                let id = String(entry[entry.index(after: colon)...])
                guard !tool.isEmpty, !id.isEmpty else {
                    throw TaskParseError(line: line, message: "会话条目 tool 与 id 均不得为空")
                }
                sessions.append(TaskSession(tool: tool, id: id))
                continue
            }
            inSessions = false

            if text == "sessions:" {
                guard seenKeys.insert("sessions").inserted else {
                    throw TaskParseError(line: line, message: "键重复: sessions")
                }
                inSessions = true
                continue
            }

            guard let colon = text.firstIndex(of: ":") else {
                throw TaskParseError(line: line, message: "缺少冒号分隔的键值行")
            }
            let key = String(text[..<colon])
            guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else {
                throw TaskParseError(line: line, message: "非法键名: \(key)")
            }
            let afterColon = text.index(after: colon)
            guard afterColon < text.endIndex, text[afterColon] == " " else {
                throw TaskParseError(line: line, message: "冒号后须恰好一个空格起值")
            }
            let value = String(text[text.index(after: afterColon)...])
            guard !value.isEmpty, !value.hasPrefix(" ") else {
                throw TaskParseError(line: line, message: "冒号后须恰好一个空格起值")
            }
            guard seenKeys.insert(key).inserted else {
                throw TaskParseError(line: line, message: "键重复: \(key)")
            }

            switch key {
            case "name":
                name = value
            case "status":
                guard let s = TaskStatus(rawValue: value) else {
                    throw TaskParseError(line: line, message: "status 取值非法: \(value)")
                }
                status = s
            case "cwd":
                cwd = value
            case "tool":
                tool = value
            case "created":
                guard let d = TaskDate.parse(value) else {
                    throw TaskParseError(line: line, message: "created 不是 ISO8601 时间: \(value)")
                }
                created = d
            case "updated":
                guard let d = TaskDate.parse(value) else {
                    throw TaskParseError(line: line, message: "updated 不是 ISO8601 时间: \(value)")
                }
                updated = d
            default:
                unknownLines.append(text)
            }
        }

        guard let name else { throw TaskParseError(line: closingLine, message: "缺少必填键: name") }
        guard let status else { throw TaskParseError(line: closingLine, message: "缺少必填键: status") }
        guard let cwd else { throw TaskParseError(line: closingLine, message: "缺少必填键: cwd") }
        guard let created else { throw TaskParseError(line: closingLine, message: "缺少必填键: created") }
        guard let updated else { throw TaskParseError(line: closingLine, message: "缺少必填键: updated") }

        return TaskFile(
            name: name, status: status, cwd: cwd, tool: tool,
            created: created, updated: updated,
            sessions: sessions, unknownLines: unknownLines, body: body
        )
    }

    // MARK: - 序列化

    /// 按规范固定键序输出：name、status、cwd、tool（有值）、created、updated、未知键、sessions（非空）
    public func serialize() -> Data {
        var s = "---\n"
        s += "name: \(name)\n"
        s += "status: \(status.rawValue)\n"
        s += "cwd: \(cwd)\n"
        if let tool {
            s += "tool: \(tool)\n"
        }
        s += "created: \(TaskDate.format(created))\n"
        s += "updated: \(TaskDate.format(updated))\n"
        for line in unknownLines {
            s += line + "\n"
        }
        if !sessions.isEmpty {
            s += "sessions:\n"
            for session in sessions {
                s += "  - \(session.tool):\(session.id)\n"
            }
        }
        s += "---\n"
        s += body
        return Data(s.utf8)
    }
}

/// ISO8601 UTC 时间读写（秒精度，如 2026-08-22T10:00:00Z）
enum TaskDate {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func parse(_ string: String) -> Date? {
        formatter.date(from: string)
    }

    static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }
}
