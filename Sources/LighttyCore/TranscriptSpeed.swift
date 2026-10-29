import Foundation

/// 一次模型请求的输出量与耗时，取自 Agent 自己写的会话日志（Claude transcript / Codex rollout）。
///
/// 耗时从请求发出（Claude 的 `api-request`）或能确认的最近输入边界（用户消息、工具输出、
/// 上一次请求结束）算到这次响应写完，含首 token 等待与网络，**不是纯解码速度**。
/// 两家都在一次请求结束后才写出完整用量，所以数值按请求更新，不逐 token 跳动。
public struct TranscriptSpeedSample: Equatable, Sendable {
    /// 同一次请求的多行（Claude 一条消息按内容块拆成多行）共用一个 id，窗口按它去重。
    public var id: String
    /// 两家的 `output_tokens` 都已包含思考 / 推理 token。
    public var outputTokens: Int
    /// 其中的思考 / 推理 token；日志没给明细时为 nil。
    public var reasoningTokens: Int?
    /// 回复正文的字符数（用户看得到的文字，不含思考与工具调用参数）。
    /// 跨家可比：同一段文字，两家分词器切出的 token 数不同。
    public var visibleCharacters: Int
    public var start: Date
    public var end: Date

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public init(id: String, outputTokens: Int, reasoningTokens: Int? = nil, visibleCharacters: Int = 0,
                start: Date, end: Date) {
        self.id = id
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.visibleCharacters = visibleCharacters
        self.start = start
        self.end = end
    }
}

/// 逐行解析会话日志。日志是私有格式：认不出的行一律跳过，缺起点的请求不出样本，不猜。
/// 行格式与时序依据见 docs/specs/output-speed.md。
public struct TranscriptSpeedParser {
    public let format: AgentSpec.TranscriptFormat
    /// 下一次请求的起点。读到日志中段时还没有，第一条请求就丢掉。
    private var boundary: Date?
    private var ordinal = 0
    /// 当前请求已写出的正文字符。Claude 按消息 id 累加各内容块；Codex 累加到用量记录为止。
    private var characters: (id: String?, count: Int) = (nil, 0)
    /// Codex：这次请求已经写出推理、回复或工具调用，还没写用量记录。
    private var responding = false

    public init(format: AgentSpec.TranscriptFormat) {
        self.format = format
    }

    public mutating func consume(_ line: Data) -> TranscriptSpeedSample? {
        ordinal += 1
        switch format {
        case .claudeTranscript: return consumeClaude(line)
        case .codexRollout: return consumeCodex(line)
        }
    }

    // MARK: Claude

    private static let claudeMarkers = [#""assistant""#, #""api-request""#, #""user""#]
        .map { Data($0.utf8) }

    private struct ClaudeEntry: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                struct Details: Decodable { var thinking_tokens: Int? }
                var output_tokens: Int?
                var output_tokens_details: Details?
            }
            struct Block: Decodable { var type: String?; var text: String? }
            var id: String?
            var model: String?
            var usage: Usage?
            var content: [Block]?
        }
        var type: String
        var timestamp: String?
        var isSidechain: Bool?
        var querySource: String?
        var message: Message?
    }

    private mutating func consumeClaude(_ line: Data) -> TranscriptSpeedSample? {
        guard Self.containsType(Self.claudeMarkers, in: line),
              let entry = try? JSONDecoder().decode(ClaudeEntry.self, from: line),
              entry.isSidechain != true, let time = Self.date(entry.timestamp) else { return nil }
        switch entry.type {
        case "api-request":
            // 标题生成等旁路请求不是这一轮的模型输出。
            if entry.querySource == nil || entry.querySource == "repl_main_thread" { advance(to: time) }
        case "user":
            // 旧版本没有 api-request 时的退路：用户消息或工具结果之后就是下一次请求。
            advance(to: time)
        case "assistant":
            // 内容块在消息写完时一起落盘，每块带自己的完成时间；最后一块即这次请求的结束。
            guard let message = entry.message, let id = message.id, message.model != "<synthetic>",
                  let tokens = message.usage?.output_tokens else { return nil }
            let text = (message.content ?? []).filter { $0.type == "text" }.reduce(0) { $0 + ($1.text?.count ?? 0) }
            characters = (id, (characters.id == id ? characters.count : 0) + text)
            guard let start = boundary, start < time else { return nil }
            return TranscriptSpeedSample(id: id, outputTokens: tokens,
                                         reasoningTokens: message.usage?.output_tokens_details?.thinking_tokens,
                                         visibleCharacters: characters.count, start: start, end: time)
        default:
            break
        }
        return nil
    }

    // MARK: Codex

    private static let codexMarkers = [#""token_usage_record""#, #""task_started""#,
                                       #""response_item""#].map { Data($0.utf8) }

    private struct CodexEntry: Decodable {
        struct Payload: Decodable {
            struct Usage: Decodable { var output_tokens: Int?; var reasoning_output_tokens: Int? }
            struct Part: Decodable { var text: String? }
            var type: String?
            var role: String?
            var usage: Usage?
            var content: [Part]?
        }
        var type: String
        var timestamp: String?
        var payload: Payload?
    }

    private mutating func consumeCodex(_ line: Data) -> TranscriptSpeedSample? {
        guard Self.containsType(Self.codexMarkers, in: line),
              let entry = try? JSONDecoder().decode(CodexEntry.self, from: line),
              let time = Self.date(entry.timestamp) else { return nil }
        let payload = entry.payload
        switch entry.type {
        case "event_msg" where payload?.type == "task_started":
            advance(to: time)
            characters = (nil, 0)
            responding = false
        case "response_item":
            // 工具输出与用户消息是下一次请求的输入；推理、回复、工具调用是这次请求的输出。
            // Codex 会在响应收尾前就开始执行工具，工具输出可能先于用量记录落盘：
            // 那时它不是新请求的起点，挪过去会把这次请求的用时砍短、速度虚高。
            let kind = payload?.type ?? ""
            switch (kind, payload?.role) {
            case ("message", "user"):
                advance(to: time)
                characters = (nil, 0)
                responding = false
            case ("message", "assistant"):
                characters.count += (payload?.content ?? []).reduce(0) { $0 + ($1.text?.count ?? 0) }
                responding = true
            case _ where kind.hasSuffix("_output"):
                if !responding { advance(to: time) }
            case _ where kind == "reasoning" || kind.hasSuffix("_call"):
                responding = true
            default:
                break // 开场的开发者上下文、工具清单等不是模型输出。
            }
        case "token_usage_record":
            defer {
                advance(to: time)
                characters = (nil, 0)
                responding = false
            }
            guard let tokens = payload?.usage?.output_tokens, let start = boundary, start < time else { return nil }
            return TranscriptSpeedSample(id: "codex-\(ordinal)", outputTokens: tokens,
                                         reasoningTokens: payload?.usage?.reasoning_output_tokens,
                                         visibleCharacters: characters.count, start: start, end: time)
        default:
            break
        }
        return nil
    }

    private static let typeKey = Data(#""type""#.utf8)

    /// 仍先按字节过滤，但不依赖 JSON 序列化器是否在冒号两侧加空白。
    /// 这只是预筛，真正的结构和语义仍由上面的解码器判断。
    private static func containsType(_ markers: [Data], in line: Data) -> Bool {
        var start = line.startIndex
        while start < line.endIndex, let key = line.range(of: typeKey, in: start..<line.endIndex) {
            start = key.upperBound
            var cursor = start
            func skipWhitespace() {
                while cursor < line.endIndex {
                    switch line[cursor] {
                    case 32, 9, 13, 10: cursor += 1
                    default: return
                    }
                }
            }
            skipWhitespace()
            guard cursor < line.endIndex, line[cursor] == 58 else { continue } // colon
            cursor += 1
            skipWhitespace()
            if markers.contains(where: { line[cursor...].starts(with: $0) }) { return true }
        }
        return false
    }

    private mutating func advance(to time: Date) {
        if boundary.map({ $0 < time }) ?? true { boundary = time }
    }

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return (try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }
}

/// 最近几次请求的合计速度：总输出 ÷ 总耗时，长请求权重大，不被一次短回复带偏。
public struct TranscriptSpeedWindow: Equatable, Sendable {
    public static let capacity = 5
    /// 几十个 token 的请求几乎全是首 token 等待，算出来的速度没有意义。
    public static let minimumTokens = 32

    public private(set) var samples: [TranscriptSpeedSample] = []

    public init() {}

    public mutating func record(_ sample: TranscriptSpeedSample) {
        guard sample.outputTokens >= Self.minimumTokens, sample.duration > 0.1 else { return }
        if let index = samples.lastIndex(where: { $0.id == sample.id }) {
            samples[index] = sample
        } else {
            samples.append(sample)
            if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
        }
    }

    public var tokensPerSecond: Double? {
        let seconds = samples.reduce(0) { $0 + $1.duration }
        guard seconds > 0 else { return nil }
        return Double(samples.reduce(0) { $0 + $1.outputTokens }) / seconds
    }

    /// 只算写了正文的请求：只调工具的请求没有可见文字，摊进去会把字符速度拉低。
    public var charactersPerSecond: Double? {
        let texts = samples.filter { $0.visibleCharacters > 0 }
        let seconds = texts.reduce(0) { $0 + $1.duration }
        guard seconds > 0 else { return nil }
        return Double(texts.reduce(0) { $0 + $1.visibleCharacters }) / seconds
    }

    public var latest: TranscriptSpeedSample? { samples.last }
}

/// 只读、增量地跟随一个会话日志文件。不是线程安全的：由一个串行队列独占。
///
/// 第一次只读文件末尾 `bootstrapBytes`，之后只读新追加的部分；一次追加超过
/// `maximumReadBytes`（比如工具结果很大）就跳到末尾重新起步，宁可丢一次样本也不阻塞。
public final class TranscriptTail {
    public static let bootstrapBytes: UInt64 = 1 << 20
    public static let maximumReadBytes: UInt64 = 8 << 20
    public static let maximumLineBytes = 16 << 20

    public let url: URL
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var partial = Data()
    /// 从文件中段起读时，第一段不是完整行。
    private var skippingPartialLine = false

    public init(url: URL) {
        self.url = url
    }

    deinit { try? handle?.close() }

    /// 新写完的完整行。文件不存在或读不了时返回空。
    public func readLines() -> [Data] {
        if handle == nil {
            guard let opened = try? FileHandle(forReadingFrom: url) else { return [] }
            handle = opened
            offset = .max
        }
        guard let handle, let size = try? handle.seekToEnd() else { return [] }
        if offset == .max || size < offset || size - offset > Self.maximumReadBytes {
            // 首次打开、文件被截断或重写、一次追加太多：都从末尾一段重新起步。
            offset = size > Self.bootstrapBytes ? size - Self.bootstrapBytes : 0
            partial.removeAll()
            skippingPartialLine = offset > 0
        }
        guard size > offset else { return [] }
        do {
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: Int(size - offset)) else { return [] }
            offset += UInt64(chunk.count)
            return split(chunk)
        } catch {
            return []
        }
    }

    private func split(_ chunk: Data) -> [Data] {
        var lines: [Data] = []
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: UInt8(ascii: "\n")) {
            if skippingPartialLine {
                skippingPartialLine = false
                partial.removeAll()
            } else {
                partial.append(chunk[start..<newline])
                if !partial.isEmpty { lines.append(partial) }
                partial = Data()
            }
            start = chunk.index(after: newline)
        }
        if !skippingPartialLine { partial.append(chunk[start...]) }
        if partial.count > Self.maximumLineBytes {
            partial.removeAll()
            skippingPartialLine = true
        }
        return lines
    }
}

/// 一个会话日志的速度读数：读取、解析、窗口合在一处，供界面在后台队列上轮询。
public final class TranscriptSpeedMeter {
    public let url: URL
    private let tail: TranscriptTail
    private var parser: TranscriptSpeedParser
    public private(set) var window = TranscriptSpeedWindow()

    public init(url: URL, format: AgentSpec.TranscriptFormat) {
        self.url = url
        tail = TranscriptTail(url: url)
        parser = TranscriptSpeedParser(format: format)
    }

    @discardableResult
    public func poll() -> TranscriptSpeedWindow {
        for line in tail.readLines() {
            if let sample = parser.consume(line) { window.record(sample) }
        }
        return window
    }
}
