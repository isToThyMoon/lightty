import Foundation

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
///
/// 旧字段 `status` 与 `sessions` 2026-09-13 移除：没有任何一方读它们的语义，
/// 应用也从不写 `sessions`。旧文件里的这两项读时忽略、写时丢弃——不进
/// `unknownLines`，否则它们会被当未知键永远搬运下去。
public struct TaskFile: Equatable {
    public var name: String
    /// 任务创建现场的工作目录（规范键 `workdir`；旧键 `cwd` 仅读取兼容，写入不再输出）
    public var workdir: String
    public var tool: String?
    public var created: Date
    public var updated: Date
    /// 未知键的原始行（不含换行符），保序保真，写回时原样输出
    public var unknownLines: [String]
    /// 正文，读写字节原样保留（包括结尾换行有无）；UTF-8 合法字符串可无损往返
    public var body: String

    public init(
        name: String,
        workdir: String,
        tool: String? = nil,
        created: Date,
        updated: Date,
        unknownLines: [String] = [],
        body: String = ""
    ) {
        self.name = name
        self.workdir = workdir
        self.tool = tool
        self.created = created
        self.updated = updated
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
        var workdir: String?
        var tool: String?
        var created: Date?
        var updated: Date?
        // 旧 sessions: 块内。块里的条目行整行跳过、不校验：字段已删，条目写成什么样都不该毙掉整个文件
        var inSessions = false
        var unknownLines: [String] = []
        var seenKeys = Set<String>()

        for (line, text) in fmLines {
            if text.hasPrefix("  - ") {
                guard inSessions else {
                    throw TaskParseError(line: line, message: "列表条目只允许出现在旧 sessions: 块内")
                }
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
            let rawKey = String(text[..<colon])
            guard !rawKey.isEmpty, !rawKey.contains(where: { $0.isWhitespace }) else {
                throw TaskParseError(line: line, message: "非法键名: \(rawKey)")
            }
            let afterColon = text.index(after: colon)
            guard afterColon < text.endIndex, text[afterColon] == " " else {
                throw TaskParseError(line: line, message: "冒号后须恰好一个空格起值")
            }
            let value = String(text[text.index(after: afterColon)...])
            guard !value.isEmpty, !value.hasPrefix(" ") else {
                throw TaskParseError(line: line, message: "冒号后须恰好一个空格起值")
            }
            // 2026-09-04 格式升版：cwd 是 workdir 的旧名，入口处归一。
            // 此后整条流水线只认识 workdir——双键并存按键重复报错。
            let key = (rawKey == "cwd") ? "workdir" : rawKey
            guard seenKeys.insert(key).inserted else {
                throw TaskParseError(line: line, message: "键重复: \(key)")
            }

            switch key {
            case "name":
                name = value
            case "status", "sessions":
                // 已移除的旧字段：读时忽略，写时自然丢弃
                break
            case "workdir":
                workdir = value
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
        guard let workdir else {
            throw TaskParseError(line: closingLine, message: "缺少必填键: workdir")
        }
        guard let created else { throw TaskParseError(line: closingLine, message: "缺少必填键: created") }
        guard let updated else { throw TaskParseError(line: closingLine, message: "缺少必填键: updated") }

        return TaskFile(
            name: name, workdir: workdir, tool: tool,
            created: created, updated: updated,
            unknownLines: unknownLines, body: body
        )
    }

    // MARK: - 序列化

    /// 按规范固定键序输出：name、workdir、tool（有值）、created、updated、未知键
    public func serialize() -> Data {
        var s = "---\n"
        s += "name: \(name)\n"
        s += "workdir: \(workdir)\n"
        if let tool {
            s += "tool: \(tool)\n"
        }
        s += "created: \(TaskDate.format(created))\n"
        s += "updated: \(TaskDate.format(updated))\n"
        for line in unknownLines {
            s += line + "\n"
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
