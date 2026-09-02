import Foundation

/// pane 里 agent 的实时活动状态。
///
/// 与 `TaskStatus`（任务文件 frontmatter 里那个已弃用字段）**无关**：
/// 那是 agent 临别时手写的一次性判断；这里是机器从 hook 生命周期事件派生的
/// 实时信号——不滞后、不会撒谎、**用完即弃**（不落盘、不恢复）。
public enum PaneActivity: String, Codable, Sendable {
    /// 无活跃 turn（SessionStart / SessionEnd）
    case idle
    /// turn 进行中（UserPromptSubmit / PostToolUse）
    case thinking
    /// 正在执行工具（PreToolUse）
    case tool
    /// 需要用户介入（Notification / PermissionRequest）
    case attention
    /// turn 完成且**未读**——唯一的粘滞态，只由 lightty 侧清除
    case done
}

/// 一发状态报文的**载荷**。信封见 `PaneStatusDatagram`。
///
/// 没有 `seq`：传输层换成 Unix domain datagram socket 之后，报文到达顺序就是发送
/// 顺序（同一 socket、同一发送方，内核接收队列是 FIFO），不需要序号去重排。
/// 旧的 `seq` 要先读磁盘上的旧值再 +1 写回——agent 并行发起多个工具调用时
/// 这个 read-modify-write 本身就在互相踩，反而是乱序的来源。
public struct PaneStatus: Codable, Sendable, Equatable {
    /// 当前恒为 1。读方遇到未知版本应整体丢弃该报文，不报错。
    public static let currentVersion = 1

    public let v: Int
    public let ts: Date
    public let state: PaneActivity
    public let agent: String?
    public let sessionID: String?
    /// `state == .tool` 时的工具名
    public let tool: String?
    /// 单行摘要（如文件路径）。**读方必须截断**，长度不可信。
    public let detail: String?
    public let cwd: String?

    enum CodingKeys: String, CodingKey {
        case v, ts, state, agent, tool, detail, cwd
        case sessionID = "session_id"
    }

    public init(
        v: Int = PaneStatus.currentVersion,
        ts: Date,
        state: PaneActivity,
        agent: String? = nil,
        sessionID: String? = nil,
        tool: String? = nil,
        detail: String? = nil,
        cwd: String? = nil
    ) {
        self.v = v
        self.ts = ts
        self.state = state
        self.agent = agent
        self.sessionID = sessionID
        self.tool = tool
        self.detail = detail
        self.cwd = cwd
    }

    // MARK: - 编解码

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // 排序键：线格式可复现，golden 用例才锁得住
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// 线格式错误。收方一律当作「这发报文不存在」处理，不向上抛。
public enum PaneStatusWireError: Error, Equatable {
    /// `v` 不是本端认识的版本
    case unsupportedVersion(Int)
    /// socket 路径超过 `sockaddr_un.sun_path` 的 104 字节上限
    case socketPathTooLong(String)
    /// `sendto` 失败，带 errno。**hook 侧一律忽略**：
    /// ENOENT（lightty 没在跑）/ ECONNREFUSED（崩溃后的残留 socket 文件）/
    /// ENOBUFS（收方卡住、内核队列满）都是正常可能，实测均在 25µs 内返回，不阻塞。
    case sendFailed(errno: Int32)
}

/// 一发状态报文的**信封**：`pane` 是路由字段，收方按它分发。
///
/// 线格式是**扁平**的一个 JSON 对象（一个 datagram 一个对象，UTF-8，≤ 4KB）：
/// ```json
/// {"v":1,"pane":"<UUID>","state":"tool","ts":"2026-09-01T12:00:00Z",
///  "agent":"claude","session_id":"…","tool":"Edit","detail":"…","cwd":"…"}
/// ```
/// datagram 天然保留消息边界，所以不需要任何 framing。
///
/// **hook 与主 app 共用本类型**——这是跨可执行文件的契约，两边各写一份编解码
/// 迟早漂移。载荷与信封共用同一层 keyed container，因此 `pane` 与状态字段同级。
public struct PaneStatusDatagram: Codable, Sendable, Equatable {
    /// 报文大小上限。收方缓冲区按它的两倍开，超限的报文会被截断成坏 JSON 而丢弃——
    /// 这正是想要的行为：一发畸形报文不该拖垮整条链路。
    public static let maxBytes = 4096

    public let pane: UUID
    public let status: PaneStatus

    private enum CodingKeys: String, CodingKey {
        case pane
    }

    public init(pane: UUID, status: PaneStatus) {
        self.pane = pane
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // UUID 的默认 Codable 就是 uuidString，且 `UUID(uuidString:)` 大小写不敏感
        pane = try container.decode(UUID.self, forKey: .pane)
        // 线上是扁平对象，所以把同一个 decoder 直接交给载荷
        let payload = try PaneStatus(from: decoder)
        // 版本闸门放在信封上：这是收方的边界，未知版本整发丢弃而不是半解析
        guard payload.v == PaneStatus.currentVersion else {
            throw PaneStatusWireError.unsupportedVersion(payload.v)
        }
        status = payload
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pane, forKey: .pane)
        try status.encode(to: encoder)
    }

    // MARK: - 编解码

    public func encode() throws -> Data {
        try PaneStatus.makeEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> PaneStatusDatagram {
        try PaneStatus.makeDecoder().decode(PaneStatusDatagram.self, from: data)
    }

    // MARK: - 发送

    /// 往 `socketPath` 发一发报文。**永不阻塞、永不抛给调用方之外的东西**。
    ///
    /// 发送方是 hook 子进程：它跑在用户 agent 的关键路径上，任何一次阻塞都是
    /// 用户会话的卡顿。SOCK_DGRAM 的三种失败都是即时返回的（本机实测）：
    /// 没有 listener → ENOENT 13µs；崩溃残留的 socket 文件 → ECONNREFUSED 22µs；
    /// 收方卡死、内核队列满 → ENOBUFS 4µs。即使是阻塞 socket 也不会挂住。
    ///
    /// 返回值给测试与诊断用；hook 侧直接丢弃。
    @discardableResult
    public func send(to socketPath: URL) -> Result<Int, PaneStatusWireError> {
        let data: Data
        do {
            data = try encode()
        } catch {
            return .failure(.sendFailed(errno: EINVAL))
        }
        return PaneStatusDatagram.send(data, to: socketPath.path)
    }

    /// 原始字节版本：测试要构造畸形报文，走同一条发送路径才有意义。
    @discardableResult
    public static func send(_ data: Data, to path: String) -> Result<Int, PaneStatusWireError> {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // sun_path 是 104 字节的定长数组，装不下就别发——截断会打到别的路径上去
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { return .failure(.socketPathTooLong(path)) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return .failure(.sendFailed(errno: errno)) }
        defer { close(fd) }

        let sent = data.withUnsafeBytes { buffer -> Int in
            withUnsafePointer(to: &addr) { addrPointer in
                addrPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(
                        fd, buffer.baseAddress, buffer.count, 0, sa,
                        socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        guard sent >= 0 else { return .failure(.sendFailed(errno: errno)) }
        return .success(sent)
    }
}
